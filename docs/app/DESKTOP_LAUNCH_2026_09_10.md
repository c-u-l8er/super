# Daily desktop launch — September 10, 2026

Use `tools/start-desktop.sh` after building the release. It prefers `wayland,x11` over an inherited test-runner GDK setting. `SUPER_DESKTOP_BACKEND` supplies an explicit troubleshooting override. The mobile observer launcher forwards through this entry point. The isolated native UI wrapper continues to choose X11 explicitly.

Syntax and stub-executable checks passed for default selection, both explicit backends, arguments, runtime path and missing release behavior. The existing native binary was launched successfully and its host environment confirmed the new backend setting. Fresh physical interaction remains pending user confirmation; the previous task recorded a successful Wayland click test. X11 fallback was not exercised on a separate X11 desktop.

Existing boundary checks passed: intent surface 6 held/0 failed, covering 25/25 mutations; WebView ACL 35 held/0 failed. No native source changed or rebuild was needed.

The same pass added two production isolated-runner regressions establishing existing new-file combined proposal and acceptance-preflight support: source plus new test, untouched source during testing, partial-save refusal, complete-save verification, later-edit refusal, and a newly occupied destination refusing without overwrite. Both passed. This corrects an overly broad new-file gap in the audit; native/provider creation workflow, deletion and recoverable whole-set application remain open.
