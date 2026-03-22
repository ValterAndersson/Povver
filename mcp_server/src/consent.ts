// mcp_server/src/consent.ts

const FIREBASE_CONFIG = {
  apiKey: process.env.FIREBASE_API_KEY || '',
  // Use default Firebase Auth domain, not mcp.povver.ai — Firebase Auth
  // needs to host /__/auth/handler for popup/redirect flows
  authDomain: 'myon-53d85.firebaseapp.com',
  projectId: process.env.GOOGLE_CLOUD_PROJECT || 'myon-53d85',
};

export function renderConsentPage(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Connect to Povver</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
      background: #0A0E14;
      color: #EAEEF3;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .container {
      max-width: 400px;
      width: 100%;
      padding: 40px 24px;
      text-align: center;
    }
    .logo {
      font-size: 32px;
      font-weight: 600;
      color: #22C59A;
      margin-bottom: 32px;
    }
    h1 {
      font-size: 20px;
      font-weight: 500;
      line-height: 1.4;
      margin-bottom: 8px;
    }
    .subtitle {
      color: rgba(255,255,255,0.55);
      font-size: 14px;
      margin-bottom: 32px;
    }
    .btn {
      display: block;
      width: 100%;
      padding: 14px;
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 10px;
      background: #111820;
      color: #EAEEF3;
      font-size: 15px;
      font-family: inherit;
      cursor: pointer;
      margin-bottom: 12px;
      transition: background 0.15s;
    }
    .btn:hover { background: #1a2230; }
    .btn-approve {
      background: #22C59A;
      color: #0A0E14;
      border-color: #22C59A;
      font-weight: 600;
      margin-top: 24px;
    }
    .btn-approve:hover { background: #1A9B79; }
    .consent-text {
      color: rgba(255,255,255,0.55);
      font-size: 13px;
      margin-top: 16px;
      line-height: 1.5;
    }
    .error { color: #ff6b6b; font-size: 14px; margin-top: 12px; display: none; }
    .step { display: none; }
    .step.active { display: block; }
    .spinner {
      display: inline-block;
      width: 20px; height: 20px;
      border: 2px solid rgba(255,255,255,0.2);
      border-top-color: #22C59A;
      border-radius: 50%;
      animation: spin 0.6s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .email-form input {
      display: block;
      width: 100%;
      padding: 12px;
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 8px;
      background: #111820;
      color: #EAEEF3;
      font-size: 15px;
      font-family: inherit;
      margin-bottom: 12px;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">Povver</div>

    <!-- Step 1: Sign in -->
    <div id="step-signin" class="step active">
      <h1>Sign in to connect your training data to Claude</h1>
      <p class="subtitle">Use the same account you use in the Povver app</p>
      <button class="btn" id="btn-apple">Continue with Apple</button>
      <button class="btn" id="btn-google">Continue with Google</button>
      <button class="btn" id="btn-email">Continue with Email</button>
      <div id="email-form" class="email-form" style="display:none;">
        <input type="email" id="email" placeholder="Email" autocomplete="email">
        <input type="password" id="password" placeholder="Password" autocomplete="current-password">
        <button class="btn" id="btn-email-submit">Sign in</button>
      </div>
      <div id="error-signin" class="error"></div>
    </div>

    <!-- Step 2: Consent -->
    <div id="step-consent" class="step">
      <h1>Allow Claude to access your Povver data?</h1>
      <p class="consent-text">
        Claude will be able to read and modify your routines, templates, and workout data.
      </p>
      <button class="btn btn-approve" id="btn-approve">Allow access</button>
      <button class="btn" id="btn-deny">Cancel</button>
      <div id="error-consent" class="error"></div>
    </div>

    <!-- Step 3: Redirecting -->
    <div id="step-redirect" class="step">
      <div class="spinner"></div>
      <p class="subtitle" style="margin-top:16px;">Redirecting to Claude...</p>
    </div>
  </div>

  <script type="module">
    import { initializeApp } from 'https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js';
    import { getAuth, signInWithPopup, signInWithEmailAndPassword, GoogleAuthProvider, OAuthProvider }
      from 'https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js';

    const app = initializeApp(${JSON.stringify(FIREBASE_CONFIG)});
    const auth = getAuth(app);
    const NONCE = ${JSON.stringify(nonce)};

    function showStep(id) {
      document.querySelectorAll('.step').forEach(s => s.classList.remove('active'));
      document.getElementById(id).classList.add('active');
    }
    function showError(stepId, msg) {
      const el = document.getElementById('error-' + stepId);
      el.textContent = msg;
      el.style.display = 'block';
    }

    let idToken = null;

    // Check if already signed in
    auth.onAuthStateChanged(async (user) => {
      if (user && !idToken) {
        idToken = await user.getIdToken();
        showStep('step-consent');
      }
    });

    // Apple
    document.getElementById('btn-apple').onclick = async () => {
      try {
        const provider = new OAuthProvider('apple.com');
        provider.addScope('email');
        provider.addScope('name');
        const result = await signInWithPopup(auth, provider);
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Google
    document.getElementById('btn-google').onclick = async () => {
      try {
        const result = await signInWithPopup(auth, new GoogleAuthProvider());
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Email toggle
    document.getElementById('btn-email').onclick = () => {
      document.getElementById('email-form').style.display = 'block';
    };

    // Email submit
    document.getElementById('btn-email-submit').onclick = async () => {
      try {
        const email = document.getElementById('email').value;
        const password = document.getElementById('password').value;
        const result = await signInWithEmailAndPassword(auth, email, password);
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Approve
    document.getElementById('btn-approve').onclick = async () => {
      try {
        showStep('step-redirect');
        const res = await fetch('/authorize/complete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id_token: idToken, nonce: NONCE }),
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error_description || data.error || 'Authorization failed');
        window.location.href = data.redirect_url;
      } catch (e) {
        showStep('step-consent');
        showError('consent', e.message);
      }
    };

    // Deny — redirect back with error per OAuth 2.1 spec
    document.getElementById('btn-deny').onclick = async () => {
      try {
        const res = await fetch('/authorize/deny', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ nonce: NONCE }),
        });
        const data = await res.json();
        if (data.redirect_url) {
          window.location.href = data.redirect_url;
        } else {
          window.close();
        }
      } catch (e) {
        window.close();
      }
    };
  </script>
</body>
</html>`;
}
