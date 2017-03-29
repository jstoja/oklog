port module Main exposing (main)

import Date exposing (fromTime)
import Dict exposing (Dict)
import Html
    exposing
        ( Html
        , button
        , div
        , footer
        , form
        , input
        , label
        , nav
        , option
        , program
        , section
        , select
        , span
        , strong
        , table
        , tbody
        , td
        , text
        , tr
        )
import Html.Attributes exposing (autofocus, class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (on, onClick, onInput, onSubmit, targetValue)
import Http exposing (Request, Response, emptyBody, expectStringResponse, request, send)
import Json.Decode as Json
import Task
import Time exposing (Time, every, hour, millisecond, minute)
import RFC3339


main : Program Never Model Msg
main =
    program
        { init = init
        , subscriptions = subscriptions
        , update = update
        , view = view
        }



-- MODEL


type alias Model =
    { lastPlan : Time
    , now : Time
    , query : Query
    , records : List Record
    , stats : Maybe Stats
    , streamRunning : Bool
    }


type alias Query =
    { regex : Bool
    , term : String
    , to : String
    , window : String
    }


type alias Record =
    { line : String
    , ulid : String
    }


type alias Stats =
    { errors : Int
    , maxDataSetSize : Int
    , nodesQueried : Int
    , segmentsQueried : Int
    }


init : ( Model, Cmd Msg )
init =
    ( Model 0 0 initQuery [] Nothing False, Task.perform Tick Time.now )


initQuery : Query
initQuery =
    Query False "" defaultTo defaultWindow


initStats : Stats
initStats =
    Stats 0 0 0 0



-- UPDATE


type Msg
    = QueryFormSubmit
    | QueryRegexUpdate String
    | QueryTermUpdate String
    | QueryToUpdate String
    | QueryWindowUpdate String
    | StatsUpdate (Result Http.Error Stats)
    | StreamCancel
    | StreamComplete String
    | StreamError String
    | StreamLines (List String)
    | Tick Time


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        QueryFormSubmit ->
            ( { model | records = [], streamRunning = True }, getRecords model.now model.query )

        QueryRegexUpdate val ->
            let
                regex =
                    if val == "regex" then
                        True
                    else
                        False

                query =
                    model.query

            in
                ( { model | query = { query | regex = regex } }, Cmd.none )

        QueryTermUpdate term ->
            let
                query =
                    model.query
            in
                ( { model | query = { query | term = term }, stats = Nothing }, Cmd.none )

        QueryToUpdate to ->
            let
                query =
                    model.query
            in
                ( { model | query = { query | to = to }, stats = Nothing }, Cmd.none )

        QueryWindowUpdate window ->
            let
                query =
                    model.query
            in
                ( { model | query = { query | window = window }, stats = Nothing }, Cmd.none )

        StatsUpdate (Ok stats) ->
            ( { model | stats = Just stats }, Cmd.none )

        StatsUpdate (Err _) ->
            ( model, Cmd.none )

        StreamCancel ->
            ( { model | streamRunning = False }, streamCancel "" )

        StreamComplete _ ->
            ( { model | streamRunning = False }, Cmd.none )

        StreamError _ ->
            ( { model | streamRunning = False }, Cmd.none )

        StreamLines lines ->
            let
                parseRecord line =
                    Record (String.dropLeft 27 line) (String.left 26 line)

                records =
                    List.map parseRecord lines

            in
                ( { model | records = (model.records ++ records) }, streamContinue "" )

        Tick now ->
            let
                timeHasPassed =
                    (abs (model.lastPlan - now)) >= 100

                termNotEmpty =
                    model.query.term /= ""

                shouldPlan =
                    (not (isPlanned model)) && timeHasPassed && termNotEmpty
            in
                case shouldPlan of
                    True ->
                        ( { model | lastPlan = now, now = now }, getStats now model.query )

                    False ->
                        ( { model | now = now }, Cmd.none )



-- SUBSCRIPTION


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ every (100 * millisecond) Tick
        , streamComplete StreamComplete
        , streamError StreamError
        , streamLine StreamLines
        ]


-- PORTS

port streamCancel : String -> Cmd msg
port streamContinue : String -> Cmd msg
port streamRequest : String -> Cmd msg

port streamComplete : ( String -> msg ) -> Sub msg
port streamError : ( String -> msg ) -> Sub msg
port streamLine : ( List String -> msg ) -> Sub msg

-- API


queryUrl : Time -> Query -> String
queryUrl now query =
    let
        from =
            Http.encodeUri (RFC3339.encode (fromTime (now - (windowDuration query.window))))

        to =
            Http.encodeUri (RFC3339.encode (fromTime now))

        parts =
            [ "/store/query?from="
            , from
            , "&to="
            , to
            , "&q="
            , query.term
            ]

    in
        if query.regex then
            String.concat (parts ++ [ "&regex" ])
        else
           String.concat parts

streamUrl : Query -> String
streamUrl query =
    let
       parts =
            [ "/store/stream?"
            , "&q="
            , query.term
            ]

    in
        if query.regex then
            String.concat (parts ++ [ "&regex" ])
        else
           String.concat parts


getRecords : Time -> Query -> Cmd Msg
getRecords now query =
    let
        url =
            if query.to == "streaming" then
                streamUrl query
            else
                queryUrl now query

    in
        streamRequest url


getStats : Time -> Query -> Cmd Msg
getStats now query =
    Http.request
        { body = emptyBody
        , expect = expectStringResponse readStats
        , headers = []
        , method = "HEAD"
        , timeout = Nothing
        , url = queryUrl now query
        , withCredentials = False
        }
        |> send StatsUpdate


readStats : Response String -> Result String Stats
readStats response =
    let
        extractHeader =
            extractStatsHeader response.headers

        errors =
            extractHeader "X-Oklog-Error-Count"

        maxDataSet =
            extractHeader "X-Oklog-Max-Data-Set-Size"

        nodesQueried =
            extractHeader "X-Oklog-Nodes-Queried"

        segmentsQueried =
            extractHeader "X-Oklog-Segments-Queried"
    in
        Ok (Stats errors maxDataSet nodesQueried segmentsQueried)


extractStatsHeader : Dict String String -> String -> Int
extractStatsHeader headers header =
    case Dict.get header headers of
        Nothing ->
            0

        Just value ->
            Result.withDefault 0 (String.toInt value)



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page" ]
        [ nav []
            [ div [ class "container" ]
                [ formQuery model ]
            ]
        , section [ id "result" ]
            [ viewRecords model
            ]
        , footer []
            [ div [ class "container" ]
                []
              --[ viewDebug model
              --]
            ]
        ]


viewDebug : Model -> Html Msg
viewDebug model =
    let
        slimModel =
            { isPlanned = isPlanned model
            , lastPlan = model.lastPlan
            , now = model.now
            , query = model.query
            , stats = model.stats
            }
    in
        div [ class "debug" ] [ text (toString slimModel) ]


viewMatchList : String -> String -> List Int -> List (Html Msg) -> List (Html Msg)
viewMatchList query line indexes elements =
    case List.head indexes of
        Nothing ->
            if String.length line == 0 then
                elements
            else
                elements ++ ([ span [] [ text line ] ])

        Just index ->
            let
                queryLen =
                    String.length query

                nonMatchElement =
                    span [] [ text (String.left index line) ]

                matchElement =
                    span [ class "highlight" ] [ text (String.left queryLen (String.dropLeft index line)) ]
            in
                viewMatchList query (String.dropLeft (index + queryLen) line) (List.drop 1 indexes) (elements ++ [ nonMatchElement, matchElement ])


viewPlan : Maybe Stats -> Html Msg
viewPlan stats =
    case stats of
        Nothing ->
            div [ class "plan" ] [ text "Your query hasn't been planned yet." ]

        Just stats ->
            let
                nodeText =
                    case stats.nodesQueried of
                        1 ->
                            "1 node"

                        _ ->
                            (toString stats.nodesQueried) ++ " nodes"

                segmentsText =
                    case stats.segmentsQueried of
                        1 ->
                            "1 segment"

                        _ ->
                            (toString stats.segmentsQueried) ++ " segments"

                elements =
                    [ span [] [ text "Your query could return " ]
                    , strong [] [ text (prettyPrintDataSet stats.maxDataSetSize) ]
                    , span [] [ text " reading " ]
                    , strong [] [ text segmentsText ]
                    , span [] [ text " on " ]
                    , strong [] [ text nodeText ]
                    ]
            in
                div [ class "plan" ] elements


viewRecord : String -> Int -> Record -> Html Msg
viewRecord query index record =
    let
        cellClass =
            if index % 2 == 0 then
                "even"
            else
                "odd"
    in
        tr [ class cellClass ]
            [ td [] (viewMatchList query record.line (String.indexes query record.line) [])
            ]


viewRecords : Model -> Html Msg
viewRecords { query, records } =
    table []
        [ tbody [] (List.map2 (viewRecord query.term) (List.range 0 (List.length records)) records)
        ]


viewResultInfo : Int -> Html Msg
viewResultInfo numRecords =
    let
        recordCount =
            if numRecords == 0 then
                span [] []
            else
                span []
                    [ text "Displaying "
                    , strong [] [ text ((toString numRecords) ++ " records") ]
                    ]
    in
        div [ class "result-info" ] [ recordCount ]


formQuery : Model -> Html Msg
formQuery model =
    let
        attrs =
            if String.length model.query.term == 0 then
                [ disabled True ]
            else
                []

        action =
            if model.streamRunning then
                button [ onClick StreamCancel ] [ text "cancel" ]
            else
                if model.query.to == "streaming" then
                    button attrs [ text "stream" ]
                else
                    button attrs [ text "query" ]

    in
        form [ id "query", onSubmit QueryFormSubmit ]
            [ div [ class "row" ]
                [ formElementQuery model.query.term
                ]
            , div [ class "actions row" ]
                [ action
                , formElementRange model.query
                , formElementAs
                ]
            , div [ class "row" ]
                [ viewPlan model.stats
                , viewResultInfo (List.length model.records)
                ]
            ]


formElementAs : Html Msg
formElementAs =
    div [ class "as" ]
        [ span [] [ text "as" ]
        , select [ on "change" (Json.map QueryRegexUpdate targetValue) ]
            [ option [ value "plain" ] [ text "plain text" ]
            , option [ value "regex" ] [ text "regex" ]
            ]
        ]

formElementRange : Query -> Html Msg
formElementRange query =
    let
        bridge =
            if query.to == "streaming" then
                span [] [ text "and" ]
            else
                span [] [ text "to" ]

    in
        div [ class "range" ]
            [ span [] [ text "from" ]
            , formElementWindow
            , bridge
            , formElementTo
            ]



formElementTo : Html Msg
formElementTo =
    select [ on "change" (Json.map QueryToUpdate targetValue) ]
        [ option [ value "streaming" ] [ text "streaming" ]
        , option [ value "0" ] [ text "now" ]
        ]


formElementQuery : String -> Html Msg
formElementQuery query =
    div [ class "term" ]
        [ input
            [ autofocus True
            , onInput QueryTermUpdate
            , placeholder "Enter query"
            , value query
            ]
            []
        ]

formElementWindow : Html Msg
formElementWindow =
    select [ on "change" (Json.map QueryWindowUpdate targetValue) ]
        [ option [ value "5m" ] [ text "5 min" ]
        , option [ value "15m" ] [ text "15 min" ]
        , option [ value "1h" ] [ text "1 hrs" ]
        , option [ value "12h" ] [ text "12 hrs" ]
        , option [ value "1d" ] [ text "1 days" ]
        , option [ value "3d" ] [ text "3 days" ]
        , option [ value "7d" ] [ text "7 days" ]
        ]



-- CONSTANTS


day : Time
day =
    24 * hour


defaultTo : String
defaultTo =
    "streaming"


defaultWindow : String
defaultWindow =
    "1h"

windowDuration : String -> Time
windowDuration window =
    case window of
        "5m" ->
            5 * minute

        "15m" ->
            15 * minute

        "12h" ->
            12 * hour

        "1d" ->
            day

        "3d" ->
            3 * day

        "7d" ->
            7 * day

        _ ->
            hour



-- HELPER


isPlanned : Model -> Bool
isPlanned model =
    case model.stats of
        Nothing ->
            False

        Just _ ->
            True

prettyPrintDataSet : Int -> String
prettyPrintDataSet size =
    if size > 1000000000 then
        toString (size // 1000000000) ++ "GB"
    else if size > 1000000 then
        toString (size // 1000000) ++ "MB"
    else if size > 1000 then
        toString (size // 1000) ++ "kB"
    else
        (toString size) ++ "Bytes"
