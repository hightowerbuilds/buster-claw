# Quality Checks

Run these checks before and after behavior-preserving refactors.

## Backend

```bash
go test ./...
go vet ./...
```

## Frontend

```bash
cd frontend
npx tsc --noEmit
npm run build
```

## Generated Code

Do not hand-edit `frontend/wailsjs/**`. Wails owns those bindings. If a Go method signature changes, regenerate the bindings through the normal Wails workflow instead of patching generated TypeScript or JavaScript directly.

## Refactor Rule

Each modularization step should keep user-visible behavior stable unless the change is explicitly scoped as a product change. Prefer small commits where a file move, extraction, or service boundary can be reviewed independently from behavior changes.
