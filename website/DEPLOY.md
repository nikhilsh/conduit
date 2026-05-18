# Deploying swe-kitty Website

This site is a static Next.js export deployed to Fyra.

## One-command deploy

From `website/`:

```sh
npm run push-code
```

That command runs:

```sh
npm run build
cp .deploy.yaml out/.deploy.yaml
cd out
fyra push
```

Deploy from `out/`, not from the `website/` source directory.

## Fyra slug

Current slug:

```sh
swe-kitty
```

Set `custom_domain` in `.deploy.yaml` once you know the hostname you want to attach.
