-- com/fourjs/aiagent/AiAgent.4gl
--
-- Server-side helper for the "fjs-ai-agent-text2sql" Genero web component.
-- NO Node.js: this Genero module IS the backend. It does three things, all
-- server-side, so the raw OpenAI key never reaches the browser:
--
--   1. mintTokenEnvelope() — POSTs to OpenAI /v1/realtime/client_secrets and
--      returns a short-lived EPHEMERAL token ("ek_…"). The browser opens the
--      Realtime (text-only) session directly with that token and STREAMS the
--      answer. The session is preconfigured here with the model, the presenter
--      instructions and the run_query / make_chart tool schemas.
--
--   2. handle() — answers the widget's tool calls. When the streaming model
--      calls run_query / make_chart, the widget relays it here; a STRONGER GPT
--      model (m_sqlModel) writes the SQL from the plain-English request, the SQL
--      runs READ-ONLY against the current database connection (native SQL), and
--      the rows / chart payload go back to the model.
--
--   3. configEnvelope() — the optional {"type":"config"} presentation push.
--
-- The database is whatever the calling program is CONNECTed to (SQLite, Informix,
-- Postgres, …); schema is introspected at runtime. See the example app in
-- examples/fjs-ai-agent-text2sql/app.
--
-- Field-value protocol over one WEBCOMPONENT STRING field (gICAPI v1.0):
--   host -> wc : {"type":"config", title, subtitle, theme, suggestions:[...]}
--   host -> wc : {"type":"token",  token, model}
--   wc -> host : {"type":"need_token"}                         Action agent_token
--   wc -> host : {"type":"tool","calls":[{id,name,args}]}      Action agent_tool
--   host -> wc : {"type":"toolresult","results":[{id,name,response}]}
PACKAGE com.fourjs.aiagent
IMPORT com
IMPORT util

PRIVATE DEFINE m_apiKey        STRING          -- OpenAI API key (server-side only)
PRIVATE DEFINE m_realtimeModel STRING          -- streaming presenter model, e.g. gpt-realtime
PRIVATE DEFINE m_sqlModel      STRING          -- SQL-author model, e.g. gpt-4o-mini
PRIVATE DEFINE m_verifyTls     SMALLINT        -- verify OpenAI's TLS cert (TRUE by default)
PRIVATE DEFINE m_dataDesc      STRING          -- one-line dataset description
PRIVATE DEFINE m_presenter     STRING          -- optional presenter-instructions override
PRIVATE DEFINE m_schema        STRING          -- cached introspected schema block
PRIVATE DEFINE m_tables        STRING          -- cached comma-list of table names
PRIVATE DEFINE m_title         STRING
PRIVATE DEFINE m_subtitle      STRING
PRIVATE DEFINE m_theme         STRING
PRIVATE DEFINE m_showTool      SMALLINT
PRIVATE DEFINE m_suggest       DYNAMIC ARRAY OF STRING
PRIVATE DEFINE m_logStarted    SMALLINT        -- startlog() called yet?

CONSTANT C_REALTIME_MODEL = "gpt-realtime"
CONSTANT C_SQL_MODEL      = "gpt-4o-mini"

-- ============================================================================
-- Configuration
-- ============================================================================
-- openaiApiKey : the OpenAI key (read it from the environment in your program).
-- realtimeModel: streaming presenter model (default gpt-realtime). Pass "" for the default.
-- sqlModel     : the SQL-author model (default gpt-4o-mini). Pass "" for the default.
PUBLIC FUNCTION configure(openaiApiKey STRING, realtimeModel STRING, sqlModel STRING)
    CALL m_suggest.clear()
    LET m_apiKey = openaiApiKey
    IF has(realtimeModel) THEN LET m_realtimeModel = realtimeModel ELSE LET m_realtimeModel = C_REALTIME_MODEL END IF
    IF has(sqlModel) THEN LET m_sqlModel = sqlModel ELSE LET m_sqlModel = C_SQL_MODEL END IF
    LET m_verifyTls = TRUE
    LET m_dataDesc = NULL
    LET m_presenter = NULL
    LET m_schema = NULL
    LET m_tables = NULL
    LET m_title = NULL
    LET m_subtitle = NULL
    LET m_theme = NULL
    LET m_showTool = FALSE
END FUNCTION

-- One-line description of the dataset, woven into both prompts.
PUBLIC FUNCTION setDataDescription(s STRING)
    LET m_dataDesc = s
END FUNCTION

-- Override the streaming model's presenter instructions (rarely needed).
PUBLIC FUNCTION setPresenterInstructions(s STRING)
    LET m_presenter = s
END FUNCTION

-- Override the introspected schema block handed to the SQL-author model.
PUBLIC FUNCTION setSchema(block STRING)
    LET m_schema = block
END FUNCTION

-- Local-dev escape hatch: disable TLS certificate verification for the OpenAI
-- calls (avoids configuring a CA bundle on the DVM). Leave verification ON in
-- production. verify=TRUE (default) verifies; FALSE disables.
PUBLIC FUNCTION setVerifyTls(verify SMALLINT)
    LET m_verifyTls = verify
END FUNCTION

PUBLIC FUNCTION setTitles(title STRING, subtitle STRING)
    LET m_title = title
    LET m_subtitle = subtitle
END FUNCTION

PUBLIC FUNCTION setTheme(theme STRING)
    LET m_theme = theme
END FUNCTION

-- Show raw tool input/output in the widget (development). Off by default.
PUBLIC FUNCTION setToolDetails(on SMALLINT)
    LET m_showTool = on
END FUNCTION

PUBLIC FUNCTION addSuggestion(s STRING)
    IF has(s) THEN
        LET m_suggest[m_suggest.getLength() + 1] = s
    END IF
END FUNCTION

-- ============================================================================
-- configEnvelope — {"type":"config",…} pushed on the first onData so the widget
-- learns its title/subtitle/theme/suggestions without .per PROPERTIES.
-- ============================================================================
PUBLIC FUNCTION configEnvelope() RETURNS STRING
    DEFINE o util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE i INTEGER
    LET o = util.JSONObject.create()
    CALL o.put("type", "config")
    IF has(m_title)    THEN CALL o.put("title", m_title) END IF
    IF has(m_subtitle) THEN CALL o.put("subtitle", m_subtitle) END IF
    IF has(m_theme)    THEN CALL o.put("theme", m_theme) END IF
    IF m_showTool THEN CALL o.put("showToolDetails", "true") END IF
    IF m_suggest.getLength() > 0 THEN
        LET arr = util.JSONArray.create()
        FOR i = 1 TO m_suggest.getLength()
            CALL arr.put(i, m_suggest[i])
        END FOR
        CALL o.put("suggestions", arr)
    END IF
    RETURN o.toString()
END FUNCTION

-- ============================================================================
-- mintTokenEnvelope — mint an OpenAI Realtime ephemeral token server-side and
-- wrap it as {"type":"token","token":"ek_…","model":…} for the widget. On any
-- failure returns an empty-token envelope (the widget then reports it can't reach
-- the server) and logs to the program log. The raw key never leaves this program.
-- ============================================================================
PUBLIC FUNCTION mintTokenEnvelope() RETURNS STRING
    DEFINE req com.HTTPRequest
    DEFINE resp com.HTTPResponse
    DEFINE root, env util.JSONObject
    DEFINE token STRING

    LET env = util.JSONObject.create()
    CALL env.put("type", "token")
    CALL env.put("token", "")

    IF NOT has(m_apiKey) THEN
        CALL logmsg("AiAgent: OpenAI API key not configured")
        RETURN env.toString()
    END IF

    TRY
        LET req = com.HTTPRequest.Create("https://api.openai.com/v1/realtime/client_secrets")
        CALL req.setMethod("POST")
        CALL req.setHeader("Authorization", "Bearer " || m_apiKey)
        CALL req.setHeader("Content-Type", "application/json")
        IF NOT m_verifyTls THEN CALL req.setVerifyServer(FALSE) END IF
        CALL req.doTextRequest(clientSecretsBody())
        LET resp = req.getResponse()
        IF resp.getStatusCode() != 200 AND resp.getStatusCode() != 201 THEN
            CALL logmsg(SFMT("AiAgent: client_secrets HTTP %1: %2", resp.getStatusCode(), resp.getTextResponse()))
            RETURN env.toString()
        END IF
        LET root = util.JSONObject.parse(resp.getTextResponse())
        LET token = root.get("value")
        CALL env.put("token", token)
        CALL env.put("model", m_realtimeModel)
        RETURN env.toString()
    CATCH
        CALL logmsg(SFMT("AiAgent: token mint failed (status %1)", status))
        RETURN env.toString()
    END TRY
END FUNCTION

-- ============================================================================
-- handle — process a field value pushed by the widget. Returns the envelope to
-- assign back to the WEBCOMPONENT field:
--   {"type":"need_token"}  -> a fresh token envelope
--   {"type":"tool",…}      -> a {"type":"toolresult",…} envelope (runs the SQL)
--   anything else          -> unchanged
-- ============================================================================
PUBLIC FUNCTION handle(fieldJson STRING) RETURNS STRING
    DEFINE root util.JSONObject
    DEFINE kind STRING
    TRY
        LET root = util.JSONObject.parse(fieldJson)
    CATCH
        RETURN fieldJson
    END TRY
    IF root IS NULL THEN RETURN fieldJson END IF
    LET kind = root.get("type")
    CASE kind
        WHEN "need_token"
            RETURN mintTokenEnvelope()
        WHEN "tool"
            RETURN handleTool(root)
        OTHERWISE
            RETURN fieldJson
    END CASE
END FUNCTION

-- ============================================================================
-- Tool dispatch
-- ============================================================================
PRIVATE FUNCTION handleTool(root util.JSONObject) RETURNS STRING
    DEFINE calls, results util.JSONArray
    DEFINE c, one, args util.JSONObject
    DEFINE out util.JSONObject
    DEFINE i INTEGER
    DEFINE id, nm, request, chartType STRING

    LET calls = root.get("calls")
    LET results = util.JSONArray.create()
    IF calls IS NOT NULL THEN
        FOR i = 1 TO calls.getLength()
            LET c = calls.get(i)
            LET id = c.get("id")
            LET nm = c.get("name")
            LET args = c.get("args")
            LET one = util.JSONObject.create()
            CALL one.put("id", id)
            CALL one.put("name", nm)
            CASE nm
                WHEN "run_query"
                    LET request = NULL
                    IF args IS NOT NULL THEN LET request = args.get("request") END IF
                    CALL one.put("response", runQueryResult(request))
                WHEN "make_chart"
                    LET request = NULL
                    LET chartType = NULL
                    IF args IS NOT NULL THEN
                        LET request = args.get("request")
                        LET chartType = args.get("chartType")
                    END IF
                    CALL one.put("response", makeChartResult(request, chartType))
                OTHERWISE
                    CALL one.put("response", errObj(SFMT("unknown tool: %1", nm)))
            END CASE
            CALL results.put(results.getLength() + 1, one)
        END FOR
    END IF

    LET out = util.JSONObject.create()
    CALL out.put("type", "toolresult")
    CALL out.put("results", results)
    RETURN out.toString()
END FUNCTION

-- run_query: NL request -> SQL (via m_sqlModel) -> read-only rows as JSON objects.
PRIVATE FUNCTION runQueryResult(request STRING) RETURNS util.JSONObject
    DEFINE o util.JSONObject
    DEFINE cols, rows util.JSONArray
    DEFINE sql, err STRING
    DEFINE t0, t1 DATETIME HOUR TO FRACTION(3)

    IF request IS NULL OR request.trim().getLength() == 0 THEN RETURN errObj("empty request") END IF
    LET sql = authorSQL(request, FALSE)
    IF sql IS NULL OR sql.getLength() == 0 THEN RETURN errObj("could not generate a query for that request") END IF
    IF NOT is_readonly(sql) THEN
        CALL logmsg(SFMT("AiAgent: run_query REJECTED by read-only guard: [%1]", sql))
        RETURN errObj("only a single read-only SELECT is allowed")
    END IF

    LET t0 = CURRENT HOUR TO FRACTION(3)
    CALL fetchObjects(sql) RETURNING cols, rows, err
    LET t1 = CURRENT HOUR TO FRACTION(3)
    CALL logmsg(SFMT("AiAgent: run_query exec start=%1 end=%2 rows=%3 err=[%4]", t0, t1, rows.getLength(), IIF(err IS NULL, "", err)))
    IF err IS NOT NULL THEN RETURN errObjSql(err, sql) END IF

    LET o = util.JSONObject.create()
    CALL o.put("success", TRUE)
    CALL o.put("sql", sql)
    CALL o.put("columns", cols)
    CALL o.put("rows", rows)
    CALL o.put("rowCount", rows.getLength())
    RETURN o
END FUNCTION

-- make_chart: NL request -> two-column SQL -> a chart payload the widget renders.
PRIVATE FUNCTION makeChartResult(request STRING, chartType STRING) RETURNS util.JSONObject
    DEFINE o, chart, cfg, point, rowObj util.JSONObject
    DEFINE cols, rows, data util.JSONArray
    DEFINE sql, err, xName, yName, ct STRING
    DEFINE i, maxPts INTEGER
    DEFINE yv DECIMAL(32, 6)
    DEFINE t0, t1 DATETIME HOUR TO FRACTION(3)

    IF request IS NULL OR request.trim().getLength() == 0 THEN RETURN errObj("empty request") END IF
    LET ct = chartType
    IF ct IS NULL OR ct.getLength() == 0 THEN LET ct = "bar" END IF

    LET sql = authorSQL(request, TRUE)
    IF sql IS NULL OR sql.getLength() == 0 THEN RETURN errObj("could not generate a query for that chart") END IF
    IF NOT is_readonly(sql) THEN
        CALL logmsg(SFMT("AiAgent: make_chart REJECTED by read-only guard: [%1]", sql))
        RETURN errObj("only a single read-only SELECT is allowed")
    END IF

    LET t0 = CURRENT HOUR TO FRACTION(3)
    CALL fetchObjects(sql) RETURNING cols, rows, err
    LET t1 = CURRENT HOUR TO FRACTION(3)
    CALL logmsg(SFMT("AiAgent: make_chart exec start=%1 end=%2 rows=%3 err=[%4]", t0, t1, rows.getLength(), IIF(err IS NULL, "", err)))
    IF err IS NOT NULL THEN RETURN errObjSql(err, sql) END IF
    IF cols.getLength() < 2 THEN RETURN errObj("the chart query must return two columns (a label and a numeric value)") END IF

    LET xName = cols.get(1)
    LET yName = cols.get(2)
    IF ct == "pie" THEN LET maxPts = 8 ELSE LET maxPts = 50 END IF

    LET data = util.JSONArray.create()
    FOR i = 1 TO rows.getLength()
        IF data.getLength() >= maxPts THEN EXIT FOR END IF
        LET rowObj = rows.get(i)
        LET point = util.JSONObject.create()
        CALL point.put(xName, rowObj.get(xName))
        LET yv = 0
        IF rowObj.get(yName) IS NOT NULL THEN LET yv = rowObj.get(yName) END IF
        CALL point.put(yName, yv)
        CALL data.put(data.getLength() + 1, point)
    END FOR

    LET cfg = util.JSONObject.create()
    CALL cfg.put("xKey", xName)
    CALL cfg.put("yKey", yName)
    LET chart = util.JSONObject.create()
    CALL chart.put("chartType", ct)
    CALL chart.put("title", request)
    CALL chart.put("config", cfg)
    CALL chart.put("data", data)
    CALL chart.put("dataPoints", data.getLength())

    LET o = util.JSONObject.create()
    CALL o.put("success", TRUE)
    CALL o.put("sql", sql)
    CALL o.put("chartType", ct)
    CALL o.put("dataPoints", data.getLength())
    CALL o.put("chart", chart)
    RETURN o
END FUNCTION

-- ============================================================================
-- SQL authoring (stronger GPT model) + execution (native, read-only)
-- ============================================================================
PRIVATE FUNCTION authorSQL(request STRING, forChart SMALLINT) RETURNS STRING
    DEFINE raw, gen STRING
    DEFINE t0, t1 DATETIME HOUR TO FRACTION(3)
    LET t0 = CURRENT HOUR TO FRACTION(3)
    LET raw = callOpenAIChat(m_sqlModel, sqlAuthorPrompt(forChart), request)
    LET t1 = CURRENT HOUR TO FRACTION(3)
    LET gen = stripFences(raw)
    CALL logmsg(SFMT("AiAgent: authorSQL model=%1 start=%2 end=%3 req=[%4] sql=[%5]", m_sqlModel, t0, t1, request, IIF(gen IS NULL, "<null>", gen)))
    RETURN gen
END FUNCTION

PRIVATE FUNCTION sqlAuthorPrompt(forChart SMALLINT) RETURNS STRING
    DEFINE p STRING
    CALL ensureSchema()
    LET p =
        "You are an expert SQLite analyst. Write ONE read-only SQLite query (SELECT or WITH) that answers the user's question, using ONLY the tables and columns in the schema below. "
        || "Output ONLY the SQL — no markdown fences, no comments, no explanation, no trailing semicolon. "
        || "Use JOINs and aggregates as needed. Dates are stored as TEXT in 'YYYY-MM-DD' form; use strftime() to group by month or year. "
        || "Add a sensible LIMIT for list-style answers. Never write to the database.\n\n"
    IF forChart THEN
        LET p = p
            || "This query feeds a CHART: return EXACTLY TWO columns — a text label/category column FIRST, then a single numeric value column SECOND. "
            || "Order rows meaningfully (value descending, or time ascending for a trend).\n\n"
    END IF
    IF has(m_dataDesc) THEN LET p = p || "Dataset: " || m_dataDesc || "\n\n" END IF
    LET p = p || "Schema:\n" || m_schema
    RETURN p
END FUNCTION

-- Call an OpenAI chat/completions model and return the message content (or NULL).
PRIVATE FUNCTION callOpenAIChat(model STRING, sys STRING, usr STRING) RETURNS STRING
    DEFINE req com.HTTPRequest
    DEFINE resp com.HTTPResponse
    DEFINE body, root, choice, msg util.JSONObject
    DEFINE msgs, choices util.JSONArray
    DEFINE m1, m2 util.JSONObject

    IF NOT has(m_apiKey) THEN RETURN NULL END IF

    LET body = util.JSONObject.create()
    CALL body.put("model", model)
    LET msgs = util.JSONArray.create()
    LET m1 = util.JSONObject.create()
    CALL m1.put("role", "system")
    CALL m1.put("content", sys)
    CALL msgs.put(1, m1)
    LET m2 = util.JSONObject.create()
    CALL m2.put("role", "user")
    CALL m2.put("content", usr)
    CALL msgs.put(2, m2)
    CALL body.put("messages", msgs)

    TRY
        LET req = com.HTTPRequest.Create("https://api.openai.com/v1/chat/completions")
        CALL req.setMethod("POST")
        CALL req.setHeader("Authorization", "Bearer " || m_apiKey)
        CALL req.setHeader("Content-Type", "application/json")
        IF NOT m_verifyTls THEN CALL req.setVerifyServer(FALSE) END IF
        CALL req.doTextRequest(body.toString())
        LET resp = req.getResponse()
        IF resp.getStatusCode() != 200 THEN
            CALL logmsg(SFMT("AiAgent: chat HTTP %1: %2", resp.getStatusCode(), resp.getTextResponse()))
            RETURN NULL
        END IF
        LET root = util.JSONObject.parse(resp.getTextResponse())
        LET choices = root.get("choices")
        IF choices IS NULL OR choices.getLength() < 1 THEN RETURN NULL END IF
        LET choice = choices.get(1)
        LET msg = choice.get("message")
        IF msg IS NULL THEN RETURN NULL END IF
        RETURN msg.get("content")
    CATCH
        CALL logmsg(SFMT("AiAgent: chat call failed (status %1)", status))
        RETURN NULL
    END TRY
END FUNCTION

-- Run an arbitrary read-only SELECT and shape the result set as
-- (columns:JSONArray[string], rows:JSONArray[object], errorOrNull:STRING).
-- Column values are stringified; a 200-row / 55 KB cap bounds the payload.
PRIVATE FUNCTION fetchObjects(p_sql STRING) RETURNS (util.JSONArray, util.JSONArray, STRING)
    DEFINE h base.SqlHandle
    DEFINE cols, rows util.JSONArray
    DEFINE rowObj util.JSONObject
    DEFINE colnames DYNAMIC ARRAY OF STRING
    DEFINE nc, i, approxLen INTEGER
    DEFINE v STRING

    LET cols = util.JSONArray.create()
    LET rows = util.JSONArray.create()
    LET nc = -1
    LET approxLen = 0

    TRY
        LET h = base.SqlHandle.create()
        CALL h.prepare(p_sql)
        CALL h.open()
        CALL h.fetch()
        WHILE sqlca.sqlcode == 0
            IF nc < 0 THEN
                LET nc = h.getResultCount()
                FOR i = 1 TO nc
                    LET colnames[i] = h.getResultName(i)
                    CALL cols.put(i, colnames[i])
                END FOR
            END IF
            LET rowObj = util.JSONObject.create()
            FOR i = 1 TO nc
                LET v = h.getResultValue(i)
                CALL rowObj.put(colnames[i], v)
                IF v IS NOT NULL THEN LET approxLen = approxLen + v.getLength() + 4 END IF
            END FOR
            CALL rows.put(rows.getLength() + 1, rowObj)
            IF rows.getLength() >= 200 OR approxLen > 55000 THEN EXIT WHILE END IF
            CALL h.fetch()
        END WHILE
        CALL h.close()
    CATCH
        RETURN cols, rows, SFMT("SQL error (sqlcode %1): %2", sqlca.sqlcode, SQLERRMESSAGE)
    END TRY
    RETURN cols, rows, NULL
END FUNCTION

-- ============================================================================
-- Schema introspection (SQLite) — cached on first use.
-- ============================================================================
PRIVATE FUNCTION ensureSchema()
    IF has(m_schema) THEN RETURN END IF
    CALL introspect()
    -- Never leave these NULL: BDL string concatenation with NULL yields NULL,
    -- which would turn the whole prompt NULL (rejected by the API).
    IF m_schema IS NULL THEN LET m_schema = "" END IF
    IF m_tables IS NULL THEN LET m_tables = "" END IF
    CALL logmsg(SFMT("AiAgent: schema introspected — %1 chars; tables=[%2]", m_schema.getLength(), m_tables))
END FUNCTION

PRIVATE FUNCTION introspect()
    DEFINE h base.SqlHandle
    DEFINE tname, ddl STRING
    DEFINE sb, tb base.StringBuffer

    -- Accumulate with base.StringBuffer, NOT the "||" operator: in Genero an
    -- empty-string seed behaves as NULL and "NULL || x" is NULL, which silently
    -- swallows every append. StringBuffer.append is immune to that.
    LET sb = base.StringBuffer.create()
    LET tb = base.StringBuffer.create()

    -- Use the CREATE TABLE DDL from sqlite_master: a plain, standard-SQL query
    -- that works through the dbmsqt driver (unlike the pragma_table_info()
    -- table-valued function, which the Genero SQL layer does not surface), and
    -- gives the model the exact column definitions.
    TRY
        LET h = base.SqlHandle.create()
        CALL h.prepare(
            "SELECT name, sql FROM sqlite_master"
            || " WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            || " ORDER BY name")
        CALL h.open()
        CALL h.fetch()
        WHILE sqlca.sqlcode == 0
            LET tname = h.getResultValue(1)
            LET ddl = h.getResultValue(2)
            IF has(ddl) THEN
                CALL sb.append(ddl)
                CALL sb.append(";\n\n")
            END IF
            IF has(tname) THEN
                IF tb.getLength() > 0 THEN CALL tb.append(", ") END IF
                CALL tb.append(tname)
            END IF
            CALL h.fetch()
        END WHILE
        CALL h.close()
    CATCH
        CALL logmsg(SFMT("AiAgent: schema introspection failed (sqlcode %1): %2", sqlca.sqlcode, SQLERRMESSAGE))
    END TRY

    LET m_schema = sb.toString()
    LET m_tables = tb.toString()
END FUNCTION

-- ============================================================================
-- Presenter instructions (the streaming model's system prompt) + tool schemas
-- ============================================================================
PRIVATE FUNCTION presenterInstructions() RETURNS STRING
    DEFINE p STRING
    IF has(m_presenter) THEN RETURN m_presenter END IF
    CALL ensureSchema()
    LET p = "You are a helpful data assistant for a business database. "
    IF has(m_dataDesc) THEN LET p = p || m_dataDesc || " " END IF
    LET p = p
        || "Answer the user's questions about the data. You do NOT know any figures yourself and you do NOT write SQL. "
        || "For ANY question that needs data, call the run_query tool with the question phrased in plain English. "
        || "For a chart, graph, plot, trend or 'visualize' request, call the make_chart tool with the question in plain English and a chartType of bar, line, area or pie. "
        || "NEVER invent numbers, names, dates or totals — only state values a tool returned. "
        || "Present answers briefly in Markdown: a short sentence or a few bullets of insight. "
        || "The UI renders charts and tables automatically, so do not repeat large tables in prose. "
        || "If a tool reports an error, tell the user you'll refine it and try a clearer request. "
    IF has(m_tables) THEN LET p = p || "Available tables: " || m_tables || "." END IF
    RETURN p
END FUNCTION

-- The JSON body for POST /v1/realtime/client_secrets: a text-only session
-- preconfigured with the presenter instructions and the two tool schemas.
PRIVATE FUNCTION clientSecretsBody() RETURNS STRING
    DEFINE body, sess, exp util.JSONObject
    DEFINE mods util.JSONArray

    LET body = util.JSONObject.create()
    LET exp = util.JSONObject.create()
    CALL exp.put("anchor", "created_at")
    CALL exp.put("seconds", 600)
    CALL body.put("expires_after", exp)

    LET sess = util.JSONObject.create()
    CALL sess.put("type", "realtime")
    CALL sess.put("model", m_realtimeModel)
    LET mods = util.JSONArray.create()
    CALL mods.put(1, "text")
    CALL sess.put("output_modalities", mods)
    CALL sess.put("instructions", presenterInstructions())
    CALL sess.put("tools", buildToolSchemas())
    CALL body.put("session", sess)

    RETURN body.toString()
END FUNCTION

PRIVATE FUNCTION buildToolSchemas() RETURNS util.JSONArray
    DEFINE arr, req, enum util.JSONArray
    DEFINE t, params, props, pReq, pType util.JSONObject

    LET arr = util.JSONArray.create()

    -- run_query(request)
    LET t = util.JSONObject.create()
    CALL t.put("type", "function")
    CALL t.put("name", "run_query")
    CALL t.put("description",
        "Answer a data question. Give the question in plain English; the server writes and runs the SQL and returns the rows.")
    LET params = util.JSONObject.create()
    CALL params.put("type", "object")
    LET props = util.JSONObject.create()
    LET pReq = util.JSONObject.create()
    CALL pReq.put("type", "string")
    CALL pReq.put("description", "the data question, in plain English")
    CALL props.put("request", pReq)
    CALL params.put("properties", props)
    LET req = util.JSONArray.create()
    CALL req.put(1, "request")
    CALL params.put("required", req)
    CALL t.put("parameters", params)
    CALL arr.put(1, t)

    -- make_chart(request, chartType)
    LET t = util.JSONObject.create()
    CALL t.put("type", "function")
    CALL t.put("name", "make_chart")
    CALL t.put("description",
        "Answer a data question with a chart. Give the question in plain English and a chartType; the server writes the SQL, runs it, and returns a chart the UI renders.")
    LET params = util.JSONObject.create()
    CALL params.put("type", "object")
    LET props = util.JSONObject.create()
    LET pReq = util.JSONObject.create()
    CALL pReq.put("type", "string")
    CALL pReq.put("description", "the data question, in plain English")
    CALL props.put("request", pReq)
    LET pType = util.JSONObject.create()
    CALL pType.put("type", "string")
    LET enum = util.JSONArray.create()
    CALL enum.put(1, "bar")
    CALL enum.put(2, "line")
    CALL enum.put(3, "area")
    CALL enum.put(4, "pie")
    CALL pType.put("enum", enum)
    CALL pType.put("description", "one of bar, line, area, pie")
    CALL props.put("chartType", pType)
    CALL params.put("properties", props)
    LET req = util.JSONArray.create()
    CALL req.put(1, "request")
    CALL req.put(2, "chartType")
    CALL params.put("required", req)
    CALL t.put("parameters", params)
    CALL arr.put(2, t)

    RETURN arr
END FUNCTION

-- ============================================================================
-- Read-only guard + helpers
-- ============================================================================
-- Accept only a single SELECT / WITH statement; reject writes, schema changes,
-- PRAGMA/ATTACH/VACUUM and any second statement. Defence-in-depth: the caller
-- should also open the connection with PRAGMA query_only = ON.
PRIVATE FUNCTION is_readonly(p_sql STRING) RETURNS SMALLINT
    DEFINE s STRING
    DEFINE semi INTEGER
    IF p_sql IS NULL THEN RETURN FALSE END IF
    -- Collapse newlines/tabs to spaces FIRST: the model formats multi-line SQL as
    -- "SELECT\n  …", and the keyword checks below are whitespace-sensitive (a
    -- newline right after SELECT would otherwise falsely reject a valid query).
    LET s = normWs(p_sql).trim()
    IF s.getLength() == 0 THEN RETURN FALSE END IF
    -- reject a second statement (non-whitespace after a ';')
    LET semi = s.getIndexOf(";", 1)
    IF semi > 0 AND s.subString(semi + 1, s.getLength()).trim().getLength() > 0 THEN
        RETURN FALSE
    END IF
    LET s = s.toUpperCase()
    IF NOT (s MATCHES "SELECT *" OR s MATCHES "SELECT" OR s MATCHES "WITH *") THEN
        RETURN FALSE
    END IF
    IF s MATCHES "* INSERT *" OR s MATCHES "* UPDATE *" OR s MATCHES "* DELETE *"
        OR s MATCHES "* DROP *" OR s MATCHES "* ALTER *" OR s MATCHES "* CREATE *"
        OR s MATCHES "* REPLACE *" OR s MATCHES "* ATTACH *" OR s MATCHES "* PRAGMA *"
        OR s MATCHES "* VACUUM *" THEN
        RETURN FALSE
    END IF
    RETURN TRUE
END FUNCTION

PRIVATE FUNCTION errObj(msg STRING) RETURNS util.JSONObject
    DEFINE o util.JSONObject
    LET o = util.JSONObject.create()
    CALL o.put("success", FALSE)
    CALL o.put("error", msg)
    RETURN o
END FUNCTION

PRIVATE FUNCTION errObjSql(msg STRING, sql STRING) RETURNS util.JSONObject
    DEFINE o util.JSONObject
    LET o = util.JSONObject.create()
    CALL o.put("success", FALSE)
    CALL o.put("error", msg)
    CALL o.put("sql", sql)
    RETURN o
END FUNCTION

-- Strip ```sql … ``` fences and a trailing ';' from a model's SQL answer.
PRIVATE FUNCTION stripFences(s STRING) RETURNS STRING
    DEFINE t STRING
    DEFINE nl, idx INTEGER
    IF s IS NULL THEN RETURN NULL END IF
    LET t = s.trim()
    IF t.getLength() >= 3 AND t.subString(1, 3) == "```" THEN
        LET nl = t.getIndexOf("\n", 1)
        IF nl > 0 THEN LET t = t.subString(nl + 1, t.getLength()) END IF
    END IF
    LET idx = t.getIndexOf("```", 1)
    IF idx > 0 THEN LET t = t.subString(1, idx - 1) END IF
    LET t = t.trim()
    IF t.getLength() > 0 AND t.getCharAt(t.getLength()) == ";" THEN
        LET t = t.subString(1, t.getLength() - 1)
    END IF
    RETURN t.trim()
END FUNCTION

PRIVATE FUNCTION has(s STRING) RETURNS SMALLINT
    IF s IS NULL THEN RETURN FALSE END IF
    RETURN s.getLength() > 0
END FUNCTION

-- Replace newline / carriage-return / tab with a single space (for the
-- whitespace-sensitive keyword checks in is_readonly).
PRIVATE FUNCTION normWs(p STRING) RETURNS STRING
    DEFINE sb base.StringBuffer
    DEFINE i INTEGER
    DEFINE c STRING
    IF p IS NULL THEN RETURN NULL END IF
    LET sb = base.StringBuffer.create()
    FOR i = 1 TO p.getLength()
        LET c = p.getCharAt(i)
        IF c == "\n" OR c == "\r" OR c == "\t" THEN
            CALL sb.append(" ")
        ELSE
            CALL sb.append(c)
        END IF
    END FOR
    RETURN sb.toString()
END FUNCTION

-- Diagnostics that never crash the flow. errorlog() raises -1340 "error log has
-- not been started" (e.g. under GAS) and that error is NOT catchable by TRY/CATCH,
-- so we must startlog() first. Do it lazily, once, to a writable temp path.
PRIVATE FUNCTION logmsg(m STRING)
    IF NOT m_logStarted THEN
        LET m_logStarted = TRUE
        TRY
            CALL startlog("/tmp/fjs-aiagent.log")
        CATCH
            RETURN  -- couldn't start a log; skip diagnostics rather than risk a crash
        END TRY
    END IF
    CALL errorlog(m)
END FUNCTION
