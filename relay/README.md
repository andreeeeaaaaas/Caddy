# Caddy issue relay

Caddy's Help › Report an issue… sends reports here. This Netlify function files each one as an issue in the GitHub repo, labelled `reported in app`, so reporters don't need GitHub accounts. The GitHub token lives only in Netlify.

## Set up

1. **GitHub token.** github.com › Settings › Developer settings › Fine-grained tokens › Generate new token.
   - Resource owner: the repo's owner
   - Repository access: Only select repositories › `Caddy`
   - Permissions: Repository › Issues › Read and write (nothing else)
   - Expiry: as long as allowed; note the date, as reports stop when it lapses
2. **Netlify site.** In the work Netlify account: Add new project › Import an existing project › this repo, with:
   - Base directory: `relay`
   - Build command: empty
   - Publish directory: `relay/public`
3. **Environment variables** (Project configuration › Environment variables):
   - `GITHUB_TOKEN`: the token from step 1
   - `GITHUB_REPO`: `andreeeeaaaaas/Caddy`
   - `CADDY_KEY`: optional, any long random string (`openssl rand -hex 24`); keeps casual traffic out
4. **Deploy**, then point the app at it in `CaddyApp/Info.plist`:
   - `CaddyReportURL`: `https://<site>.netlify.app/api/report`
   - `CaddyReportKey`: the same `CADDY_KEY`, or empty if you didn't set one

Until `CaddyReportURL` is set, the app's form says it can't send yet and offers Copy Report.

## Try it

```bash
curl -X POST https://<site>.netlify.app/api/report \
  -H 'Content-Type: application/json' -H 'X-Caddy-Key: <key>' \
  -d '{"title":"Test report","description":"Sent with curl.","contact":"","system":{"version":"0.1","build":"1","os":"macOS 26.2","model":"Mac16,1"}}'
```

It answers `{"number": <issue>}`. Reports are limited to 5 a minute from one address.

## Notes

- The key ships inside the app, so it isn't a secret from anyone who has the app; it only keeps out traffic that doesn't come from Caddy. Change it in both places if it's abused.
- Reports carry the app version, macOS version and Mac model, plus what the reporter types. No scripts, frames or videos.
