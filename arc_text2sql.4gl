-- =============================================================================
#+ Demo program for the fjs-ai-agent-text2sql package.
#+
#+ Connects to the PostgreSQL database arc_demo (customers and delivery notes),
#+ configures the AiAgent module and wires the two widget actions: mint the
#+ ephemeral OpenAI token and answer the model's tool calls (read-only SQL).
-- =============================================================================

IMPORT FGL com.fourjs.aiagent.AiAgent

CONSTANT C_BD = "arc_demo"

-- =============================================================================
#+ Program entry point.
-- =============================================================================

MAIN
    DEFINE agent_data STRING
    DEFINE apikey STRING

    DEFER INTERRUPT
    OPTIONS INPUT WRAP

    LET apikey = fgl_getenv("OPENAI_API_KEY")
    IF apikey IS NULL OR apikey.getLength() == 0 THEN
        DISPLAY "OPENAI_API_KEY is not set"
        EXIT PROGRAM 1
    END IF

    TRY
        CONNECT TO C_BD AS "main"
    CATCH
        DISPLAY SFMT("Cannot connect to %1: %2 %3", C_BD, sqlca.sqlcode, SQLERRMESSAGE)
        EXIT PROGRAM 1
    END TRY

    -- Read-only hardening on top of the module's SELECT-only guard
    TRY
        EXECUTE IMMEDIATE "SET default_transaction_read_only = on"
    CATCH
        DISPLAY SFMT("Warning: cannot set read-only mode: %1", SQLERRMESSAGE)
    END TRY

    CALL configureAgent(apikey)

    CLOSE WINDOW SCREEN
    OPEN WINDOW w_main WITH FORM "arc_text2sql"

    LET agent_data = AiAgent.configEnvelope()

    INPUT BY NAME agent_data WITHOUT DEFAULTS
        ATTRIBUTES(UNBUFFERED, ACCEPT = FALSE, CANCEL = FALSE)

        ON ACTION agent_token ATTRIBUTES(DEFAULTVIEW = NO)
            LET agent_data = AiAgent.mintTokenEnvelope()

        ON ACTION agent_tool ATTRIBUTES(DEFAULTVIEW = NO)
            LET agent_data = AiAgent.handle(agent_data)

        ON ACTION close ATTRIBUTES(TEXT = "Quit")
            EXIT INPUT
    END INPUT

    DISCONNECT "main"
END MAIN

-- =============================================================================
#+ Configure the AiAgent module for the arc_demo database.
#+
#+ The module's schema introspection and SQL-author prompt target SQLite, so
#+ the PostgreSQL schema is supplied explicitly with setSchema() and the data
#+ description tells the SQL-author model which dialect to write.
#+
#+ @param apikey  OpenAI API key (stays server-side)
-- =============================================================================

PRIVATE FUNCTION configureAgent(apikey STRING)
    CALL AiAgent.configure(apikey, "gpt-realtime", "gpt-4o-mini")
    -- Local development only: do not verify the TLS certificate of OpenAI
    CALL AiAgent.setVerifyTls(FALSE)
    -- Development: show the generated SQL in the tool rows
    CALL AiAgent.setToolDetails(TRUE)

    CALL AiAgent.setSchema(schemaBlock())
    CALL AiAgent.setDataDescription(
        "IMPORTANT: the database is PostgreSQL, NOT SQLite - use PostgreSQL syntax "
        || "(to_char(fecha,'YYYY-MM'), date_trunc, EXTRACT, ::numeric, ILIKE; never strftime). "
        || "Table and column names are in Spanish. clientes = customers, albaranes = delivery notes "
        || "(cliente references clientes.codigo), paises = country names per language "
        || "(join clientes.pais = paises.codigo AND paises.idioma = 'en'). "
        || "albaranes.importe is the amount; albaranes.estado is A (open), B (blocked), "
        || "F (invoiced) or N (cancelled). clientes.tipo is A (old) or N (new). "
        || "Always answer in the language of the user's question, using English labels for states and types.")
    CALL AiAgent.setTitles("Text2SQL demo - Data Agent", "Ask about customers and delivery notes")
END FUNCTION

-- =============================================================================
#+ Schema of arc_demo handed to the SQL-author model.
#+
#+ @return DDL-like description of the tables, with column comments
-- =============================================================================

PRIVATE FUNCTION schemaBlock() RETURNS STRING
    DEFINE sb base.StringBuffer
    LET sb = base.StringBuffer.create()

    CALL sb.append("CREATE TABLE paises (\n")
    CALL sb.append("  codigo CHAR(2) NOT NULL,  -- ISO 3166 alpha-2 country code\n")
    CALL sb.append("  idioma CHAR(2) NOT NULL,  -- language of the name: es, en\n")
    CALL sb.append("  nombre VARCHAR(60) NOT NULL,  -- country name in that language\n")
    CALL sb.append("  PRIMARY KEY (codigo, idioma)\n);\n\n")

    CALL sb.append("CREATE TABLE clientes (\n")
    CALL sb.append("  codigo SERIAL PRIMARY KEY,  -- customer id\n")
    CALL sb.append("  nombre VARCHAR(60) NOT NULL,  -- customer name\n")
    CALL sb.append("  nif VARCHAR(12),  -- tax id\n")
    CALL sb.append("  direccion VARCHAR(80),\n  cpostal VARCHAR(5),\n  ciudad VARCHAR(40),\n  provincia VARCHAR(25),\n")
    CALL sb.append("  pais CHAR(2) NOT NULL,  -- country code, references paises.codigo\n")
    CALL sb.append("  telefono VARCHAR(15),\n  email VARCHAR(60),\n")
    CALL sb.append("  tipo CHAR(1) NOT NULL,  -- A = old customer, N = new customer\n")
    CALL sb.append("  latitud NUMERIC(9,6),\n  longitud NUMERIC(9,6),\n  observaciones VARCHAR(1000)\n);\n\n")

    CALL sb.append("CREATE TABLE albaranes (\n")
    CALL sb.append("  numero SERIAL PRIMARY KEY,  -- delivery note number\n")
    CALL sb.append("  estado CHAR(1) NOT NULL,  -- A = open, B = blocked, F = invoiced, N = cancelled\n")
    CALL sb.append("  cliente INTEGER NOT NULL REFERENCES clientes(codigo),\n")
    CALL sb.append("  fecha DATE NOT NULL,  -- delivery note date\n")
    CALL sb.append("  importe NUMERIC(12,2) NOT NULL,  -- amount\n")
    CALL sb.append("  ffacturacion DATE,  -- invoicing date (state F only)\n")
    CALL sb.append("  fanulacion DATE,  -- cancellation date (state N only)\n")
    CALL sb.append("  observaciones VARCHAR(1000)\n);\n")

    RETURN sb.toString()
END FUNCTION
