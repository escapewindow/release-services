module App.ReleaseDashboard exposing (..) 

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput, onSubmit)
import HtmlParser exposing (parse)
import HtmlParser.Util exposing (toVirtualDom)
import String
import Dict
import Json.Decode as Json exposing (Decoder, (:=))
import Json.Decode.Extra as JsonExtra exposing ((|:))
import Json.Encode as JsonEncode
import RemoteData as RemoteData exposing ( WebData, RemoteData(Loading, Success, NotAsked, Failure) )
import Http
import Task exposing (Task)
import Basics exposing (Never)

import App.User as User exposing (Hawk)
import App.Utils exposing (onChange)

-- Models

type BugEditor = FlagsEditor | ApprovalEditor | NoEditor

type alias Contributor = {
  email: String,
  name: String,
  avatar: String
}

type alias UpliftRequest = {
  bugzilla_id: Int,
  author: Contributor,
  comment: String
}

type alias UpliftVersion = {
  name: String,
  status: String,
  attachments: List String
}

type alias Patch = {
  source: String,
  additions: Int,
  deletions: Int,
  changes: Int,
  url: String
}

type alias BugUpdate = {
  error : Bool,
  message : String
}

type alias Bug = {
  id: Int,
  bugzilla_id: Int,
  url: String,
  summary: String,
  keywords: List String,
  flags_status : Dict.Dict String String,
  flags_tracking : Dict.Dict String String,

  -- Users
  creator: Contributor,
  assignee: Contributor,
  reviewers: List Contributor,

  -- Uplift
  uplift_request: Maybe UpliftRequest,
  uplift_versions: Dict.Dict String UpliftVersion,

  -- Patches
  patches: Dict.Dict String Patch,

  -- Actions on bug
  editor: BugEditor,
  edits : Dict.Dict String String,
  attachments : Dict.Dict String (Dict.Dict String String), -- uplift approval
  update : (WebData BugUpdate)
}

type alias Analysis = {
  id: Int,
  name: String,
  count: Int,
  bugs: List Bug
}

type alias Model = {
  -- All analysis in use
  all_analysis : WebData (List Analysis),

  -- Current Analysis used
  current_analysis : WebData (Analysis),

  -- Backend base endpoint
  backend_dashboard_url : String,

  -- Can we publish any update to bugzilla 
  bugzilla_available : Bool
}

type Msg
   = FetchedAllAnalysis (WebData (List Analysis))
   | FetchedAnalysis (WebData Analysis)
   | FetchedBug (WebData Bug)
   | FetchAllAnalysis
   | FetchAnalysis Int
   | ShowBugEditor Bug BugEditor
   | EditBug Bug String String
   | EditUplift Bug UpliftVersion String
   | PublishEdits Bug
   | SavedBugEdit Bug (WebData BugUpdate)
   | ProcessWorkflow Hawk
   | UserMsg User.Msg


init : String -> (Model, Cmd Msg)
init backend_dashboard_url =
  -- Init empty model
  ({
    all_analysis = NotAsked,
    current_analysis = NotAsked,
    backend_dashboard_url = backend_dashboard_url,
    bugzilla_available = False
  }, Cmd.none)

-- Update

update : Msg -> Model -> User.Model -> (Model, User.Model, Cmd Msg)
update msg model user =
  case msg of
    FetchAllAnalysis ->
      let
        newModel = { model | all_analysis = Loading }
      in
        fetchAllAnalysis newModel user

    FetchAnalysis analysisId ->
      let
        newModel = { model | current_analysis = Loading }
      in
        fetchAnalysis newModel user analysisId

    FetchedAllAnalysis allAnalysis ->
      (
        { model | all_analysis = allAnalysis, current_analysis = NotAsked },
        user,
        Cmd.none
      )

    FetchedAnalysis analysis ->
      (
        { model | current_analysis = analysis },
        user,
        Cmd.none
      )

    ProcessWorkflow workflow ->
      -- Process task from workflow
      let
        cmd = case workflow.requestType of
          User.AllAnalysis ->
            processAllAnalysis workflow
          User.Analysis ->
            processAnalysis workflow
          _ ->
            Cmd.none
      in
        (model, user, cmd)

    UserMsg msg ->
      -- Process messages for user
      let
        (newUser, workflow, userCmd) = User.update msg user
      in
        ( model, user, Cmd.map UserMsg userCmd)

    ShowBugEditor bug show ->
      let
        -- Mark a bug as being edited
        model' = updateBug model bug.id (\b -> { b | editor = show, edits = Dict.empty, attachments = Dict.empty })

        -- Check current bugzilla status
        bz_auth = case user.bugzilla_check of
          Success auth -> auth
          _ -> False
        model'' = { model' | bugzilla_available = bz_auth }
      in
        (model'', user, Cmd.none)

    EditBug bug key value ->
      -- Store a bug edit
      let
        edits = Dict.insert key value bug.edits
        model' = updateBug model bug.id (\b -> { b | edits = edits })
      in
        (model', user, Cmd.none)

    EditUplift bug version status ->
      -- Store an uplift approval
      -- Inverse data : we must send updates on attachments !
      let
        attachments = List.map (\a -> (a, Dict.singleton version.name status)) version.attachments 
              |> Dict.fromList
              |> Dict.foldl mergeAttachments bug.attachments
        model' = updateBug model bug.id (\b -> { b | attachments = attachments })
      in
        (model', user, Cmd.none)

    PublishEdits bug ->
      -- Send edits to backend
      case bug.editor of
        FlagsEditor ->
          publishBugEdits model user bug
        ApprovalEditor ->
          publishApproval model user bug
        NoEditor ->
          (model, user, Cmd.none)

    FetchedBug bug ->
      -- Store updated bug - post edits
      let
        model' = case bug of
          Success bug' -> updateBug model bug'.id (\b -> bug')
          _ -> model
      in
        (model', user, Cmd.none)

    SavedBugEdit bug update ->
      -- Store bug update from bugzilla
      let
        model' = updateBug model bug.id (\b -> { b | update = update, editor = NoEditor })
      in
        (model', user, Cmd.none)

mergeAttachments: String -> Dict.Dict String String
  -> Dict.Dict String (Dict.Dict String String)
  -> Dict.Dict String (Dict.Dict String String)
mergeAttachments aId versions attachments =
  -- Like Dict.union on 2 levels
  let
    out = case Dict.get aId attachments of
      Just attachment -> Dict.union versions attachment 
      Nothing -> versions
  in
    Dict.insert aId out attachments

updateBug: Model -> Int -> (Bug -> Bug) -> Model
updateBug model bugId callback =
  -- Update a bug in current analysis
  -- using a callback
  case model.current_analysis of
    Success analysis ->
      let

        -- Rebuild bugs list
        bugs = List.map (\b -> if b.id == bugId then (callback b) else b) analysis.bugs

        -- Rebuild analysis
        analysis' = { analysis | bugs = bugs }

      in
        { model | current_analysis = Success analysis' }

    _ -> model

fetchAllAnalysis : Model -> User.Model -> (Model, User.Model, Cmd Msg)
fetchAllAnalysis model user =
  -- Fetch all analysis summary
  let 
    params = {
      backend = {
        method = "GET",
        url = model.backend_dashboard_url ++ "/analysis"
      },
      target = Nothing,
      body = Nothing,
      requestType = User.AllAnalysis
    }
    (user', workflow, userCmd) = User.update (User.InitHawkRequest params) user
  in
    (
      model,
      user',
      Cmd.map UserMsg userCmd
    )

processAllAnalysis : Hawk -> Cmd Msg
processAllAnalysis workflow =
  -- Decode and save all analysis
  case workflow.task of
    Just task ->
      (Http.fromJson decodeAllAnalysis task)
      |> RemoteData.asCmd
      |> Cmd.map FetchedAllAnalysis

    Nothing ->
        Cmd.none

fetchAnalysis : Model -> User.Model -> Int -> (Model, User.Model, Cmd Msg)
fetchAnalysis model user analysis_id =
  -- Fetch a specific analysis with details
  let 
    params = {
      backend = {
        method = "GET",
        url = model.backend_dashboard_url ++ "/analysis/" ++ (toString analysis_id)
      },
      target = Nothing,
      body = Nothing,
      requestType = User.Analysis
    }
    (user', workflow, userCmd) = User.update (User.InitHawkRequest params) user
  in
    (
      model,
      user',
      Cmd.map UserMsg userCmd
    )

processAnalysis : Hawk -> Cmd Msg
processAnalysis workflow =
  -- Decode and save a single analysis
  case workflow.task of
    Just task ->
      (Http.fromJson decodeAnalysis task)
      |> RemoteData.asCmd
      |> Cmd.map FetchedAnalysis

    Nothing ->
        Cmd.none

publishBugEdits: Model -> User.Model -> Bug -> (Model, User.Model, Cmd Msg)
publishBugEdits model user bug =
  -- Publish all bug edits directly to Bugzilla
  case user.bugzilla of
    Just bugzilla ->
      let
        comment = Dict.get "comment" bug.edits |> Maybe.withDefault "Modified from Uplift Dashboard."
        edits = Dict.filter (\k v -> not (k == "comment")) bug.edits

        flags = List.map (\(k,v) -> ("cf_" ++ k, JsonEncode.string v)) (Dict.toList edits)

        -- Build payload for bugzilla
        payload = JsonEncode.encode 0 (
          JsonEncode.object ([
            ("comment", JsonEncode.object [
              ("body", JsonEncode.string comment),
              ("is_markdown", JsonEncode.bool True)
            ])
          ] ++ flags )
        )
        l = Debug.log "Bugzilla payload" payload

        task = User.buildBugzillaTask bugzilla {
          method = "PUT",
          url = "/bug/" ++ (toString bug.bugzilla_id)
        } (Just payload)

        cmd = (Http.fromJson decodeBugUpdate task)
          |> RemoteData.asCmd
          |> Cmd.map (SavedBugEdit bug)
      in
        (model, user, cmd)

    Nothing ->
      -- No credentials !
      (model, user, Cmd.none)

publishApproval: Model -> User.Model -> Bug -> (Model, User.Model, Cmd Msg)
publishApproval model user bug =
  case user.bugzilla of
    Just bugzilla ->
      let
        -- Make a request per updated attachment
        comment = Dict.get "comment" bug.edits |> Maybe.withDefault "Modified from Uplift Dashboard."
        commands = List.map (updateAttachment bug bugzilla comment) (Dict.toList bug.attachments)
      in
        (model, user, Cmd.batch commands)
    Nothing ->
      -- No credentials !
      (model, user, Cmd.none)

updateAttachment: Bug -> User.BugzillaCredentials -> String -> (String, Dict.Dict String String) -> Cmd Msg
updateAttachment bug bugzilla comment (attachment_id, versions) =
  -- Build payload for bugzilla
  -- to update an atachment
  let

    flags = List.map encodeFlag (Dict.toList versions)

    payload = JsonEncode.encode 0 (
      JsonEncode.object [
        ("comment", JsonEncode.string comment),
        ("flags", JsonEncode.list flags)
      ]
    )
    l = Debug.log "Bugzilla payload" payload

    task = User.buildBugzillaTask bugzilla {
      method = "PUT",
      url = "/bug/attachment/" ++ attachment_id
    } (Just payload)

  in   
    (Http.fromJson decodeBugUpdate task)
      |> RemoteData.asCmd
      |> Cmd.map (SavedBugEdit bug)

encodeFlag: (String, String) -> JsonEncode.Value
encodeFlag (name, status) =
  -- Json encode an attachment flag
  JsonEncode.object [
    ("name", JsonEncode.string name),
    ("status", JsonEncode.string status)
  ]

decodeBugUpdate : Decoder BugUpdate
decodeBugUpdate =
  Json.oneOf [
    -- Error decoder
    Json.object2 BugUpdate
      ("error" := Json.bool)
      ("message" := Json.string),

    -- Success decoder
    Json.object2 BugUpdate
      (Json.succeed False) -- no error
      (Json.succeed "")
  ]

decodeAllAnalysis : Decoder (List Analysis)
decodeAllAnalysis =
  Json.list decodeAnalysis

decodeAnalysis : Decoder Analysis
decodeAnalysis =
  Json.object4 Analysis
    ("id" := Json.int)
    ("name" := Json.string)
    ("count" := Json.int)
    ("bugs" := Json.list decodeBug)

decodeBug : Decoder Bug
decodeBug =
  Json.succeed Bug
    |: ("id" := Json.int)
    |: ("bugzilla_id" := Json.int)
    |: ("url" := Json.string)
    |: ("summary" := Json.string)
    |: ("keywords" := Json.list Json.string)
    |: ("flags_status" := Json.dict Json.string)
    |: ("flags_tracking" := Json.dict Json.string)
    |: ("creator" := decodeContributor)
    |: ("assignee" := decodeContributor)
    |: ("reviewers" := (Json.list decodeContributor))
    |: (Json.maybe ("uplift" := decodeUpliftRequest))
    |: ("versions" := (Json.dict decodeVersion))
    |: ("patches" := (Json.dict decodePatch))
    |: (Json.succeed NoEditor) -- not editing at first
    |: (Json.succeed Dict.empty) -- not editing at first
    |: (Json.succeed Dict.empty) -- not editing at first
    |: (Json.succeed NotAsked) -- no updates at first
 
decodePatch : Decoder Patch
decodePatch =
  Json.object5 Patch
    ("source" := Json.string)
    ("changes_add" := Json.int)
    ("changes_del" := Json.int)
    ("changes_size" := Json.int)
    ("url" := Json.string)

decodeVersion : Decoder UpliftVersion
decodeVersion =
  Json.object3 UpliftVersion
    ("name" := Json.string)
    ("status" := Json.string)
    ("attachments" := Json.list Json.string)

decodeContributor : Decoder Contributor
decodeContributor = 
  Json.object3 Contributor
    ("email" := Json.string)
    ("real_name" := Json.string)
    ("avatar" := Json.string)

decodeUpliftRequest : Decoder UpliftRequest
decodeUpliftRequest  =
  Json.object3 UpliftRequest
    ("id" := Json.int)
    ("author" := decodeContributor)
    ("comment" := Json.string)

-- Subscriptions

subscriptions : Analysis -> Sub Msg
subscriptions analysis =
  Sub.none


-- Views

view : Model -> Html Msg
view model =
  case model.current_analysis of
    NotAsked ->
      div [class "alert alert-info"] [text "Please select an analysis in the navbar above."]

    Loading ->
      div [class "alert alert-info"] [text "Loading your bugs..."]

    Failure err ->
      div [class "alert alert-danger"] [text ("Error: " ++ toString err)]

    Success analysis ->
      viewAnalysis model analysis


viewAnalysis: Model -> Analysis -> Html Msg
viewAnalysis model analysis =
  div []
    [ h1 [] [text ("Listing all " ++ analysis.name ++ " uplifts for review:")]
    , div [class "bugs"] (List.map (viewBug model) analysis.bugs)
    ]


viewBug: Model -> Bug -> Html Msg
viewBug model bug =
  div [class "bug"] [
    h4 [] [text bug.summary],
    p [class "summary"] (
      [
        a [class "text-muted monospace", href bug.url, target "_blank"] [text ("#" ++ (toString bug.bugzilla_id))]
      ]
      ++ (List.map viewVersionTag (Dict.toList bug.uplift_versions))
      ++ (List.map (\k -> span [class "label label-default"] [text k]) bug.keywords)
    ),
    div [class "row"] [
      div [class "col-xs-4"] ([
        viewContributor bug.creator "Creator",
        viewContributor bug.assignee "Assignee"
      ] ++ (List.map (\x -> viewContributor x "Reviewer") bug.reviewers)),
      div [class "col-xs-4"] [
        viewUpliftRequest bug.uplift_request
      ],
      div [class "col-xs-4"] [
        case bug.editor of
          FlagsEditor -> viewFlagsEditor model bug
          ApprovalEditor -> viewApprovalEditor model bug
          NoEditor -> viewBugDetails bug
      ]
    ]
  ]

viewVersionTag: (String, UpliftVersion) -> Html Msg
viewVersionTag (name, version) =
  case version.status of
    "?" -> span [class "label label-info"] [text name]
    "+" -> span [class "label label-success"] [text name]
    "-" -> span [class "label label-danger"] [text name]
    _ ->  span [class "label label-default"] [text name]

viewContributor: Contributor -> String -> Html Msg
viewContributor user title = 
  div [class "user row"] [
    div [class "pull-sm-left hidden-xs"] [
      img [class "avatar img-fluid img-rounded", src user.avatar] []
    ],
    div [class "col-xs-8 col-sm-10"] [
      p [class "lead"] [text user.name],
      p [] [
        a [href ("mailto:" ++ user.email)] [text user.email]
      ],
      p [] [
        span [class "label label-default"] [text title]
      ]
    ]
  ]

viewUpliftRequest: Maybe UpliftRequest -> Html Msg
viewUpliftRequest maybe =
  case maybe of
    Just request -> 
      div [class "uplift-request", id (toString request.bugzilla_id)] [
        viewContributor request.author "Uplift request",
        div [class "comment"] (toVirtualDom (parse request.comment))
      ]
    Nothing -> 
      div [class "alert alert-warning"] [text "No uplift request."]

viewBugDetails: Bug -> Html Msg
viewBugDetails bug =
  div [class "details"] [

    case bug.update of
      Success update ->
        if update.error then
          div [class "alert alert-danger"] [
            h4 [] [text "Error during the update"],
            p [] [text update.message]
          ]

        else
          div [class "alert alert-success"] [
            h4 [] [text "Bug updated !"],
            p [] [text update.message]
          ]
      Failure err ->
        div [class "alert alert-danger"] [
          h4 [] [text "Error"],
          p [] [text ("An error occurred during the update: " ++ (toString err))]
        ]
      _ ->
        span [] [],
    h5 [] [text "Patches"],
    div [class "patches"] (List.map viewPatch (Dict.toList bug.patches)),

    viewFlags bug,
  
    -- Start editing
    h5 [] [text "Actions"],
    p [class "actions"] [
      button [class "btn btn-sm btn-primary", onClick (ShowBugEditor bug ApprovalEditor)] [text "Approve uplift"],
      button [class "btn btn-sm btn-secondary", onClick (ShowBugEditor bug FlagsEditor)] [text "Edit flags"],
      a [class "btn btn-sm btn-success", href bug.url, target "_blank"] [text "View on Bugzilla"]
    ]
  ]

viewPatch: (String, Patch) -> Html Msg
viewPatch (patchId, patch) =
  div [class "patch"] [
    --span [class "label label-info -pill", title "Changes size"] [text (toString patch.changes)],
    a [href patch.url, target "_blank", title ("On " ++ patch.source)] [text ((if patch.changes > 0 then "Patch" else "Test") ++ " " ++ patchId)],
    span [class "changes"] [text "("],
    span [class "changes additions"] [text ("+" ++ (toString patch.additions))],
    span [class "changes deletions"] [text ("-" ++ (toString patch.deletions))],
    span [class "changes"] [text ")"]
  ]

viewFlags: Bug -> Html Msg
viewFlags bug =
  let
    flags_status = Dict.filter (\k v -> not (v == "---")) bug.flags_status
    flags_tracking = Dict.filter (\k v -> not (v == "---")) bug.flags_tracking
  in 
    div [class "flags"] [
      h5 [] [text "Status flags"],
      if Dict.isEmpty flags_status then
        p [class "text-warning"] [text "No status flags set."]
      else
        ul [] (List.map viewStatusFlag (Dict.toList flags_status)),

      h5 [] [text "Tracking flags"],
      if Dict.isEmpty flags_tracking then
        p [class "text-warning"] [text "No tracking flags set."]
      else
        ul [] (List.map viewTrackingFlag (Dict.toList flags_tracking))
    ]

viewStatusFlag (key, value) =
  li [] [
    strong [] [text key],
    case value of
      "affected" -> span [class "label label-danger"] [text value]
      "verified" -> span [class "label label-info"] [text value]
      "fixed" -> span [class "label label-success"] [text value]
      "wontfix" -> span [class "label label-warning"] [text value]
      _ -> span [class "label label-default"] [text value]
  ]

editStatusFlag: Bug -> (String, String) -> Html Msg
editStatusFlag bug (key, flag_value) =
  let
    possible_values = ["affected", "verified", "fixed", "wontfix", "---"]
  in
    div [class "form-group row"] [
      label [class "col-sm-6 col-form-label"] [text key],
      div [class "col-sm-6"] [
        select [class "form-control form-control-sm", onChange (EditBug bug ("status_" ++ key))]
          (List.map (\x -> option [ selected (x == flag_value)] [text x]) possible_values)
      ]
    ]

viewTrackingFlag (key, value) =
  li [] [
    strong [] [text key],
    case value of
      "+" -> span [class "label label-success"] [text value]
      "-" -> span [class "label label-danger"] [text value]
      "?" -> span [class "label label-info"] [text value]
      _ -> span [class "label label-default"] [text value]
  ]

editTrackingFlag: Bug -> (String, String) -> Html Msg
editTrackingFlag bug (key, flag_value) =
  let
    possible_values = ["+", "-", "?", "---"]
  in
    div [class "form-group row"] [
      label [class "col-sm-6 col-form-label"] [text key],
      div [class "col-sm-6"] [
        select [class "form-control form-control-sm", onChange (EditBug bug ("tracking_" ++ key))]
          (List.map (\x -> option [ selected (x == flag_value)] [text x]) possible_values)
      ]
    ]

viewFlagsEditor: Model -> Bug -> Html Msg
viewFlagsEditor model bug =
  -- Show the form to edit flags
  Html.form [class "editor", onSubmit (PublishEdits bug)] [
    div [class "col-xs-12 col-sm-6"]
      ([h4 [] [text "Status"] ] ++ (List.map (\x -> editStatusFlag bug x) (Dict.toList bug.flags_status))),
    div [class "col-xs-12 col-sm-6"]
      ([h4 [] [text "Tracking"] ] ++ (List.map (\x -> editTrackingFlag bug x) (Dict.toList bug.flags_tracking))),
    div [class "form-group"] [
      textarea [class "form-control", placeholder "Your comment", onInput (EditBug bug "comment")] []
    ],
    p [class "text-warning", hidden model.bugzilla_available] [text "You need to setup your Bugzilla account on the uplift dashboard before using this action."],
    p [class "actions"] [
      button [class "btn btn-success", disabled (not model.bugzilla_available)] [text "Update bug"],
      span [class "btn btn-secondary", onClick (ShowBugEditor bug NoEditor)] [text "Cancel"]
    ]
  ]

editApproval: Bug -> (String, UpliftVersion) -> Html Msg
editApproval bug (name, version) =
  let
    possible_values = ["+", "-", "?"]
  in
    div [class "form-group row"] [
      label [class "col-sm-6 col-form-label"] [text version.name],
      div [class "col-sm-6"] [
        select [class "form-control form-control-sm", onChange (EditUplift bug version)]
          (List.map (\x -> option [ selected (x == version.status)] [text x]) possible_values)
      ]
    ]

viewApprovalEditor: Model -> Bug -> Html Msg
viewApprovalEditor model bug =
  -- Show the form to approve the uplift request
  Html.form [class "editor", onSubmit (PublishEdits bug)] [
    div [class "col-xs-12"]
      ([h4 [] [text "Approve uplift"] ] ++ (List.map (\x -> editApproval bug x) (Dict.toList bug.uplift_versions))),
    div [class "form-group"] [
      textarea [class "form-control", placeholder "Your comment", onInput (EditBug bug "comment")] []
    ],
    p [class "text-warning", hidden model.bugzilla_available] [text "You need to setup your Bugzilla account on the uplift dashboard before using this action."],
    p [class "actions"] [
      button [class "btn btn-success", disabled (not model.bugzilla_available)] [text "Approve uplift"],
      span [class "btn btn-secondary", onClick (ShowBugEditor bug NoEditor)] [text "Cancel"]
    ]
  ]
