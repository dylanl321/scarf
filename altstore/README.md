# ScarfGo sideload source

This folder is an [AltStore source](https://faq.altstore.io/developers/make-a-source) that [Feather](https://github.com/claration/Feather) also understands. GitHub Actions publishes a rolling unsigned IPA to the `scarfgo-sideload` release and refreshes `source.json` there.

## Add the source

Use this URL in AltStore or Feather:

```
https://github.com/OWNER/REPO/releases/download/scarfgo-sideload/source.json
```

Replace `OWNER/REPO` with this GitHub repository (for example `dylanl321/scarf`).

- **AltStore / SideStore:** Browse → Sources → + → paste the URL.
- **Feather:** Sources → add repository → paste the same URL.

The IPA on that release is unsigned. AltStore and Feather re-sign it with your Apple ID or certificate when you install. New CI builds bump `CFBundleVersion`, so those apps can offer an update without a new marketing version.

Do not add a GitHub Actions artifact URL — those expire and require a login.
