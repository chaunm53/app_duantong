# CI Patch – Files to copy into your repo
Copy the folders in this archive into your repo root:
- .github/workflows/contracts-types-ci.yml
- packages/ci-tools/package.json
- packages/ci-tools/scripts/validate-schemas.mjs
- packages/types/package.json
- packages/types/scripts/generate-types.mjs
- packages/types/src/index.ts

Then edit your root package.json per PATCH_root_package.json.txt.
Run:
  npm i -w @he-sinh-thai/types -w @he-sinh-thai/ci-tools
  npm run build:types
  npm run contracts:check
