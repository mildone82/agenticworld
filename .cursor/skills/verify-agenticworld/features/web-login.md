# Web login

Web login is the email form at `/login`. The user enters an email, chooses Continue, and then enters a verification code.

## Sub-features

- `login-form` shows the sign-in heading, the email field, and Continue.
- `login-submit` requests a code for the typed email. Completing sign-in needs the code from email or, when no email backend is configured, from the API log.

## How to get to it (user POV)

- Open `http://127.0.0.1:3000/login`.
- Choose the Email field (`#login-email`, placeholder `you@example.com`).
- Choose the button named `Continue`.

## Driving it with verify-agenticworld

Preconditions:

- Full launch is ready and `./scripts/verify/doctor.sh` reports `instance.frontend=ok`.
- No proof may call the code-verification API unless a real code was issued for an address the run is allowed to use.

- **Open the form.** Run `./scripts/verify/drive.sh web-login`. Exit code 0. `drive/web-login.html` contains `login-email` or `Sign in to Multica`. `drive/web-login.meta.txt` has `exit=0` and the `/login` URL.
- **Submit is a separate step.** Fill `#login-email` in a browser only when you can also read the resulting code from the configured mailbox or the API log line for that address. Save the form after Continue shows `Check your email`. Do not mark submit done from the empty form alone.

## Gotchas

- If port 3000 is closed, the drive exits 1 with `result=unmet_precondition`. The CLI version command is not a substitute.
- The page is a client component. The proof string has to be in the saved body; a bare HTTP 200 is not enough.
- With no Resend/SMTP configuration the API logs the verification code instead of sending mail. Copying that code into evidence is fine only when the log line itself contains no other secret. Do not invent a code.
- `Continue` stays disabled until the email field has a value.
