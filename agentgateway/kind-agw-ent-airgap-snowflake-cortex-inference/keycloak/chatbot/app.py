import os
import sys
import time
import base64
import json
import logging
import requests
import streamlit as st

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("chatbot")

AGW_URL = os.environ.get("AGW_URL", "http://snowflake-cortex-gw.agentgateway-system.svc:8080")
KEYCLOAK_BASE = os.environ.get("KEYCLOAK_BASE", "http://keycloak.agentgateway-system.svc:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "agentgateway")
CLIENT_ID = os.environ.get("CLIENT_ID", "chatbot-ui")
MODEL = os.environ.get("MODEL", "snowflake-arctic")

TOKEN_URL = f"{KEYCLOAK_BASE}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
USERINFO_URL = f"{KEYCLOAK_BASE}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/userinfo"

st.set_page_config(page_title="AGW Chatbot", page_icon="🤖", layout="wide")


def decode_jwt_payload(token):
    payload = token.split(".")[1]
    payload += "=" * (4 - len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def login(username, password, ui_log):
    log.info("=== LOGIN START user=%s ===", username)
    ui_log.append(("step", "1. Requesting token from Keycloak", f"POST {TOKEN_URL}"))
    ui_log.append(("detail", "Grant type", "password"))
    ui_log.append(("detail", "Client ID", CLIENT_ID))
    ui_log.append(("detail", "Username", username))
    ui_log.append(("detail", "Scope", "openid email profile"))

    log.info("POST %s grant_type=password client_id=%s username=%s", TOKEN_URL, CLIENT_ID, username)
    resp = requests.post(TOKEN_URL, data={
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "username": username,
        "password": password,
        "scope": "openid email profile",
    }, timeout=10)

    log.info("Keycloak token response: HTTP %d", resp.status_code)
    ui_log.append(("result", "Keycloak response", f"HTTP {resp.status_code}"))

    if resp.status_code != 200:
        err = resp.json().get("error_description", resp.text)
        log.error("Login failed for user=%s: %s", username, err)
        ui_log.append(("error", "Login failed", err))
        return None, err

    data = resp.json()
    claims = decode_jwt_payload(data["access_token"])

    log.info("Token received: iss=%s sub=%s azp=%s preferred_username=%s expires_in=%s",
             claims.get("iss"), claims.get("sub"), claims.get("azp"),
             claims.get("preferred_username"), data.get("expires_in"))

    ui_log.append(("success", "Access token received", f"expires_in={data.get('expires_in')}s"))
    ui_log.append(("step", "2. JWT claims from Keycloak", ""))
    ui_log.append(("detail", "iss (issuer)", claims.get("iss", "?")))
    ui_log.append(("detail", "sub (subject)", claims.get("sub", "?")))
    ui_log.append(("detail", "azp (client)", claims.get("azp", "?")))
    ui_log.append(("detail", "preferred_username", claims.get("preferred_username", "?")))
    ui_log.append(("detail", "typ", claims.get("typ", "?")))

    log.info("GET %s (userinfo)", USERINFO_URL)
    ui_log.append(("step", "3. Fetching user info", f"GET {USERINFO_URL}"))
    user = requests.get(USERINFO_URL,
        headers={"Authorization": f"Bearer {data['access_token']}"}, timeout=10)
    user_info = user.json() if user.status_code == 200 else {}
    log.info("UserInfo response: HTTP %d email=%s", user.status_code, user_info.get("email", "n/a"))
    ui_log.append(("result", "UserInfo response", f"HTTP {user.status_code}"))
    if user_info:
        ui_log.append(("detail", "email", user_info.get("email", "n/a")))
        ui_log.append(("detail", "name", user_info.get("name", "n/a")))

    log.info("=== LOGIN SUCCESS user=%s ===", claims.get("preferred_username", username))
    ui_log.append(("success", "Login complete", f"User: {claims.get('preferred_username', username)}"))

    return {
        "access_token": data["access_token"],
        "refresh_token": data.get("refresh_token", ""),
        "expires_at": time.time() + data.get("expires_in", 300),
        "user": user_info,
    }, None


def refresh_token():
    auth = st.session_state.get("auth")
    if not auth:
        return None
    remaining = int(auth["expires_at"] - time.time())
    if remaining > 30:
        log.info("Token still valid (%ds remaining)", remaining)
        return auth["access_token"]
    log.info("Token expiring in %ds, refreshing via refresh_token grant", remaining)
    resp = requests.post(TOKEN_URL, data={
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": auth["refresh_token"],
    }, timeout=10)
    log.info("Refresh response: HTTP %d", resp.status_code)
    if resp.status_code != 200:
        log.warning("Refresh failed, session expired")
        st.session_state.pop("auth", None)
        return None
    data = resp.json()
    claims = decode_jwt_payload(data["access_token"])
    log.info("Token refreshed: sub=%s expires_in=%s", claims.get("sub"), data.get("expires_in"))
    st.session_state["auth"] = {
        "access_token": data["access_token"],
        "refresh_token": data.get("refresh_token", auth["refresh_token"]),
        "expires_at": time.time() + data.get("expires_in", 300),
        "user": auth["user"],
    }
    return data["access_token"]


def render_log(log):
    for entry_type, label, value in log:
        if entry_type == "step":
            st.markdown(f"**{label}**")
            if value:
                st.code(value, language=None)
        elif entry_type == "detail":
            st.markdown(f"&nbsp;&nbsp;&nbsp;&nbsp;`{label}`: {value}")
        elif entry_type == "result":
            st.info(f"{label}: **{value}**")
        elif entry_type == "success":
            st.success(f"{label}: {value}")
        elif entry_type == "error":
            st.error(f"{label}: {value}")


# --- Login screen ---
if "auth" not in st.session_state:
    st.title("AgentGateway Chatbot")

    col_form, col_log = st.columns([1, 1])

    with col_form:
        st.markdown("### Login")
        st.caption(f"Keycloak realm: `{KEYCLOAK_REALM}` | Client: `{CLIENT_ID}`")
        with st.form("login_form"):
            username = st.text_input("Username")
            password = st.text_input("Password", type="password")
            submitted = st.form_submit_button("Login", type="primary", use_container_width=True)

    with col_log:
        st.markdown("### Auth Flow")
        if submitted and username and password:
            log = []
            auth_data, error = login(username, password, log)
            render_log(log)
            if not error:
                st.session_state["auth"] = auth_data
                time.sleep(1.5)
                st.rerun()
        else:
            st.caption("Login to see the authentication flow details.")
            st.markdown("""
**What will happen:**
1. Chatbot sends credentials to Keycloak token endpoint
2. Keycloak validates and returns a signed JWT
3. Chatbot fetches user info from Keycloak
4. Each chat message is sent to AGW with `Authorization: Bearer <JWT>`
5. AGW validates JWT signature via Keycloak JWKS
6. If valid, AGW forwards to the LLM backend
""")
    st.stop()

# --- Logged in - Chat UI ---
auth = st.session_state["auth"]
user = auth.get("user", {})
display_name = user.get("preferred_username") or user.get("name") or user.get("email") or "User"

st.title("AgentGateway Chatbot")
st.caption(f"Logged in as **{display_name}** | Model: `{MODEL}`")

if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if "auth_log" in msg:
            with st.expander("Auth details"):
                render_log(msg["auth_log"])

if prompt := st.chat_input("Ask something..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        auth_log = []
        try:
            auth_log.append(("step", "1. Getting access token", ""))
            token = refresh_token()
            if not token:
                st.error("Session expired. Please log in again.")
                st.session_state.pop("auth", None)
                st.rerun()

            was_refreshed = st.session_state["auth"]["access_token"] != auth["access_token"]
            if was_refreshed:
                auth_log.append(("success", "Token refreshed", "via refresh_token grant"))
            else:
                remaining = int(st.session_state["auth"]["expires_at"] - time.time())
                auth_log.append(("success", "Token still valid", f"{remaining}s remaining"))

            claims = decode_jwt_payload(token)
            auth_log.append(("detail", "iss", claims.get("iss", "?")))
            auth_log.append(("detail", "sub", claims.get("sub", "?")))
            auth_log.append(("detail", "preferred_username", claims.get("preferred_username", "?")))

            log.info("=== CHAT REQUEST user=%s prompt='%s' ===", display_name, prompt[:80])
            auth_log.append(("step", "2. Sending request to AGW", f"POST {AGW_URL}/v1/chat/completions"))
            auth_log.append(("detail", "Authorization", f"Bearer {token[:40]}..."))
            auth_log.append(("detail", "Model", MODEL))

            log.info("POST %s/v1/chat/completions model=%s Authorization=Bearer %s...", AGW_URL, MODEL, token[:20])
            resp = requests.post(
                f"{AGW_URL}/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": MODEL,
                    "messages": [{"role": m["role"], "content": m["content"]} for m in st.session_state.messages],
                },
                timeout=60,
            )

            log.info("AGW response: HTTP %d", resp.status_code)
            auth_log.append(("result", "AGW response", f"HTTP {resp.status_code}"))

            if resp.status_code == 401:
                log.error("JWT rejected by AGW: %s", resp.text)
                auth_log.append(("error", "JWT rejected by AGW", resp.text))
                st.error(f"**401 Unauthorized** — JWT rejected by AGW\n\n```\n{resp.text}\n```")
                reply = "[Auth failed]"
            elif resp.status_code != 200:
                log.warning("Upstream error: HTTP %d %s", resp.status_code, resp.text[:200])
                auth_log.append(("error", f"Upstream returned {resp.status_code}", resp.text[:200]))
                st.error(f"**{resp.status_code}** from upstream\n\n```\n{resp.text}\n```")
                reply = f"[Error {resp.status_code}]"
            else:
                log.info("LLM response received via AGW")
                auth_log.append(("success", "LLM response received", "via AGW"))
                reply = resp.json()["choices"][0]["message"]["content"]
                st.markdown(reply)
        except requests.exceptions.ConnectionError as e:
            log.error("Connection failed to %s: %s", AGW_URL, e)
            auth_log.append(("error", "Connection failed", str(e)))
            st.error(f"**Connection failed** to `{AGW_URL}`\n\n```\n{e}\n```")
            reply = "[Connection error]"
        except Exception as e:
            log.error("Unexpected error: %s", e, exc_info=True)
            auth_log.append(("error", "Unexpected error", str(e)))
            st.error(f"**Error**: {e}")
            reply = f"[Error: {e}]"

        with st.expander("Auth details", expanded=True):
            render_log(auth_log)

    st.session_state.messages.append({"role": "assistant", "content": reply, "auth_log": auth_log})

# --- Sidebar ---
with st.sidebar:
    st.header(f"Welcome, {display_name}")

    remaining = int(st.session_state["auth"]["expires_at"] - time.time())
    if remaining > 0:
        st.success(f"Token valid ({remaining}s remaining)")
    else:
        st.warning("Token expired — will refresh on next message")

    with st.expander("JWT Claims"):
        try:
            claims = decode_jwt_payload(st.session_state["auth"]["access_token"])
            st.json(claims)
        except Exception:
            st.code(st.session_state["auth"]["access_token"][:80] + "...", language=None)

    st.divider()
    st.markdown("**Architecture**")
    st.markdown("""
```
You (browser)
  |
  |  username/password
  v
Chatbot App ──> Keycloak (token endpoint)
  |               returns JWT
  |
  |  Bearer <JWT>
  v
AgentGateway ──> validates JWT (JWKS)
  |
  |  + Snowflake PAT
  v
Snowflake Cortex (LLM)
```
""")
    st.divider()
    st.caption(f"Client: `{CLIENT_ID}`")
    st.caption(f"AGW: `{AGW_URL}`")
    st.caption(f"Keycloak: `{KEYCLOAK_BASE}`")

    st.divider()
    if st.button("Logout", type="secondary", use_container_width=True):
        log.info("=== LOGOUT user=%s ===", display_name)
        st.session_state.clear()
        st.rerun()
