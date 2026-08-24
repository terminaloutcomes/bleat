+++
title = "Bleat Audiobookshelf OIDC Setup"
description = "Configure Audiobookshelf and an OAuth2/OpenID Connect provider for secure sign-in with Bleat."
template = "admin-guide.html"
+++


## This has layers, like an onion

> Bleat → Audiobookshelf → OpenID provider

Audiobookshelf is the OIDC client. Register Audiobookshelf—not Bleat—with Kanidm, Keycloak, Authentik, or another provider. The provider issues credentials to Audiobookshelf; Bleat receives only Audiobookshelf credentials through its mobile bridge.

Users enter credentials only in the system browser and auth interface. They never enter credentials into Bleat.

## Before you start

Use Audiobookshelf 2.26.0 or newer, which is Bleat's minimum supported server version.
Give Audiobookshelf and the provider stable HTTPS addresses with certificates trusted by iOS and by each server.

Have administrator access to both Audiobookshelf and the identity provider.

## Step 1 - Register Audiobookshelf at the auth provider

This is the part where you register Audiobookshelf with your auth provider. These details might change and you should refer to Audiobookshelf's documentation for up-to-date advice!

Create one OIDC client for Audiobookshelf using the authorization-code flow. Record its client ID and client secret for Audiobookshelf.

Allow the exact Audiobookshelf mobile redirect that matches the public server URL:

- `https://<audiobookshelf-host>/auth/openid/mobile-redirect`
- `https://<audiobookshelf-host>/<prefix>/auth/openid/mobile-redirect`

Use the root-hosted form (the first one) only when Audiobookshelf is served at the host root. Use the prefixed form when its public base URL contains a path.

Audiobookshelf web login may also require the `/auth/openid/callback` redirect shown in its Authentication settings. Follow the provider's instructions for client type, scopes, claims, signing algorithm, and exact redirect matching.

## Step 2 - Configure Audiobookshelf

In Audiobookshelf, open Settings → Authentication and enable OpenID Connect Authentication.

Enter the provider issuer URL. Use Audiobookshelf's auto-populate action where supported, then verify the authorization, token, user-info, JWKS, and optional logout endpoints.

Enter the Audiobookshelf client ID and secret from the provider, and select a signing algorithm the provider advertises.

If Audiobookshelf is served below a path prefix, select that prefix under Web Redirect URLs Subfolder. Confirm the mobile callback displayed by Audiobookshelf exactly matches the URI registered at the provider.

Under Allowed Mobile Redirect URIs, add Bleat's exact callback:

`bleat://oauth2redirect`

Do not use a wildcard and do not substitute a bundle identifier. Configure the button label, automatic launch, user matching, and registration policy for your site, then save the settings.

## Step 3 - Verify Audiobookshelf first

Open the server's public /status endpoint (`https://<audiobookshelf-host>/<prefix>/status`) beneath the same base URL you will enter in Bleat. Its JSON response must list openid in authMethods.

Confirm OIDC login works in Audiobookshelf's web interface and that its logs show the expected public HTTPS redirect. Then enter the same Audiobookshelf base URL in Bleat. Bleat should show the server-configured OpenID "`login with <x>`" button.

## Troubleshooting

### Bleat does not show an OpenID button

Check the server's `/status` response. Audiobookshelf is not advertising OIDC when openid is absent from `authMethods`; correct its Authentication settings first.

### The provider reports a redirect URI mismatch

Compare the entire provider redirect URL character for character with Audiobookshelf's displayed mobile callback. Check the scheme, host, port, path prefix, and trailing path. Register exact URIs instead of wildcards.

### The browser returns to an error or the wrong path

Confirm the reverse proxy preserves the public host, HTTPS scheme, and Audiobookshelf prefix. Select the matching redirect subfolder in Audiobookshelf, and make sure the prefixed mobile redirect reaches Audiobookshelf rather than a proxy 404 page.

### The provider login succeeds but Bleat does not reopen

Confirm `bleat://oauth2redirect` is an exact Allowed Mobile Redirect URI in Audiobookshelf. It belongs there—not in the provider's client redirect list.

### HTTPS or certificate errors appear

Bleat uses normal system trust and has no certificate bypass. The Audiobookshelf certificate must be trusted by the device, and Audiobookshelf must trust and resolve the provider's HTTPS endpoint.

### Audiobookshelf reports issuer, token, claim, or signature errors

Compare its issuer, client credentials, endpoints, signing algorithm, scopes, and claim mappings with the provider configuration. These are Audiobookshelf-to-provider failures; changing Bleat cannot repair them.

## Upstream Documentation

- [Audiobookshelf OIDC authentication](https://audiobookshelf.org/docs/documentation/server-management/oidc-authentication)
- [Kanidm OAuth2 and OIDC integration](https://kanidm.github.io/kanidm/master/integrations/oauth2.html)
- [Keycloak client configuration](https://www.keycloak.org/docs/latest/server_admin/#_clients)
- [authentik OAuth2 and OIDC provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
