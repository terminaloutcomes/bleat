#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_oidc_port="${BLEAT_OIDC_HTTPS_PORT:-13480}"
readonly bleat_https_root_port="${BLEAT_HTTPS_ROOT_PORT:-13478}"
readonly bleat_https_prefix_port="${BLEAT_HTTPS_PREFIX_PORT:-13479}"
readonly bleat_oidc_base="https://caddy:8445/realms/bleat"
readonly bleat_client_id="audiobookshelf"
readonly bleat_client_secret="bleat-oidc-client-secret"
readonly bleat_username="${BLEAT_TEST_USERNAME:?BLEAT_TEST_USERNAME is required}"
readonly bleat_password="${BLEAT_TEST_PASSWORD:?BLEAT_TEST_PASSWORD is required}"
readonly bleat_ca_file="${BLEAT_LIVE_CA_CERT:?BLEAT_LIVE_CA_CERT is required}"

bleat_wait_keycloak() {
    local attempt
    for attempt in {1..60}; do
        if /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 2 \
            --cacert "${bleat_ca_file}" \
            "https://localhost:${bleat_oidc_port}/realms/bleat/.well-known/openid-configuration" \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    print -u2 "Keycloak did not become ready"
    return 1
}

bleat_configure_keycloak_client() {
    local admin_token
    local client_uuid
    local client
    admin_token="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --cacert "${bleat_ca_file}" \
            --data-urlencode 'username=admin' \
            --data-urlencode 'password=bleat-keycloak-admin' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=admin-cli' \
            "https://localhost:${bleat_oidc_port}/realms/master/protocol/openid-connect/token" \
            | jq --exit-status --raw-output '.access_token'
    )"
    client_uuid="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --cacert "${bleat_ca_file}" \
            --header "Authorization: Bearer ${admin_token}" \
            "https://localhost:${bleat_oidc_port}/admin/realms/bleat/clients?clientId=audiobookshelf" \
            | jq --exit-status --raw-output '.[0].id'
    )"
    client="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --cacert "${bleat_ca_file}" \
            --header "Authorization: Bearer ${admin_token}" \
            "https://localhost:${bleat_oidc_port}/admin/realms/bleat/clients/${client_uuid}" \
            | jq \
                --arg root "https://localhost:${bleat_https_root_port}/auth/openid/mobile-redirect" \
                --arg prefix "https://localhost:${bleat_https_prefix_port}/audiobookshelf/auth/openid/mobile-redirect" \
                '.redirectUris = [$root, $prefix]'
    )"
    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --cacert "${bleat_ca_file}" \
        --request PUT \
        --header "Authorization: Bearer ${admin_token}" \
        --header 'Content-Type: application/json' \
        --data "${client}" \
        "https://localhost:${bleat_oidc_port}/admin/realms/bleat/clients/${client_uuid}" \
        >/dev/null
}

bleat_configure_server() {
    local base_url="$1"
    local redirect_subfolder="$2"
    local login_payload
    local access_token
    login_payload="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --request POST \
            --header 'Content-Type: application/json' \
            --header 'x-return-tokens: true' \
            --data "{\"username\":\"${bleat_username}\",\"password\":\"${bleat_password}\"}" \
            "${base_url}/login"
    )"
    access_token="$(
        print -r -- "${login_payload}" \
            | jq --exit-status --raw-output \
                '.user.accessToken | select(type == "string" and length > 0)'
    )"

    local payload
    payload="$(jq -n \
        --arg issuer "${bleat_oidc_base}" \
        --arg authorization "${bleat_oidc_base}/protocol/openid-connect/auth" \
        --arg token "${bleat_oidc_base}/protocol/openid-connect/token" \
        --arg userinfo "${bleat_oidc_base}/protocol/openid-connect/userinfo" \
        --arg jwks "${bleat_oidc_base}/protocol/openid-connect/certs" \
        --arg logout "${bleat_oidc_base}/protocol/openid-connect/logout" \
        --arg client_id "${bleat_client_id}" \
        --arg client_secret "${bleat_client_secret}" \
        --arg redirect_subfolder "${redirect_subfolder}" \
        '{
          authActiveAuthMethods: ["local", "openid"],
          authOpenIDIssuerURL: $issuer,
          authOpenIDAuthorizationURL: $authorization,
          authOpenIDTokenURL: $token,
          authOpenIDUserInfoURL: $userinfo,
          authOpenIDJwksURL: $jwks,
          authOpenIDLogoutURL: $logout,
          authOpenIDClientID: $client_id,
          authOpenIDClientSecret: $client_secret,
          authOpenIDTokenSigningAlgorithm: "RS256",
          authOpenIDButtonText: "Sign in with Keycloak",
          authOpenIDAutoLaunch: false,
          authOpenIDAutoRegister: true,
          authOpenIDMobileRedirectURIs: ["bleat://oauth2redirect"],
          authOpenIDSubfolderForRedirectURLs: $redirect_subfolder
        }'
    )"

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --request PATCH \
        --header "Authorization: Bearer ${access_token}" \
        --header 'Content-Type: application/json' \
        --data "${payload}" \
        "${base_url}/api/auth-settings" \
        >/dev/null

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --header "Authorization: Bearer ${access_token}" \
        "${base_url}/api/auth-settings" \
        | jq --exit-status \
            --arg redirect_subfolder "${redirect_subfolder}" \
            '.authOpenIDMobileRedirectURIs == ["bleat://oauth2redirect"]
                and .authOpenIDSubfolderForRedirectURLs == $redirect_subfolder' \
        >/dev/null
}

bleat_wait_keycloak
bleat_configure_keycloak_client
bleat_configure_server "http://127.0.0.1:${bleat_root_port}" ""
bleat_configure_server \
    "http://127.0.0.1:${bleat_prefix_port}/audiobookshelf" \
    "/audiobookshelf"
