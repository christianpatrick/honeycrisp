import Foundation

/// The few pages remote access shows in a browser: passkey setup, consent,
/// and errors. Each is self-contained, locked down with a per-response CSP
/// nonce, and escapes everything it interpolates, because client names
/// come from strangers (GH-16).
enum RemotePages {
    static func consent(
        clientName: String, redirectHost: String, loopback: Bool, data: [String: Any]
    ) -> HTTPResponse {
        let name = escape(clientName)
        let host = escape(redirectHost)
        let warning =
            loopback
            ? #"<p class="warn">That address is on the device you're using now. Only allow this if you just started connecting from an app on this device.</p>"#
            : ""
        let body = """
            <h1>Connect \(name) to Honeycrisp?</h1>
            <p><strong>\(name)</strong> wants to use Honeycrisp on this Mac. It gets the same access your permission settings give every client, and sends still wait for your approval on the Mac.</p>
            <p>After you allow it, your browser goes back to <strong>\(host)</strong>.</p>
            \(warning)
            <div class="actions"><button id="deny" type="button">Don't allow</button><button id="allow" class="primary" type="button">Allow with passkey</button></div>
            """
        return page(status: 200, title: "Connect a client", body: body, data: data, script: consentScript)
    }

    static func setup(data: [String: Any]) -> HTTPResponse {
        let body = """
            <h1>Add a passkey for remote access</h1>
            <p>Remote clients ask you to sign in with this passkey before they can use Honeycrisp on this Mac. Save it somewhere that syncs, like iCloud Keychain, so you can sign in from your iPhone too.</p>
            <div class="actions"><button id="create" class="primary" type="button">Create passkey</button></div>
            """
        return page(status: 200, title: "Add a passkey", body: body, data: data, script: setupScript)
    }

    static func needsPasskey() -> HTTPResponse {
        let body = """
            <h1>Add a passkey first</h1>
            <p>Honeycrisp asks for a passkey before a remote client can connect, and this Mac doesn't have one for this address yet.</p>
            <p>Open Honeycrisp's settings on your Mac, choose Add a passkey, then start connecting again from your client.</p>
            """
        return page(status: 200, title: "Add a passkey first", body: body, data: nil, script: nil)
    }

    static func problem(_ status: Int, title: String, message: String) -> HTTPResponse {
        let body = "<h1>\(escape(title))</h1>\n<p>\(escape(message))</p>"
        return page(status: status, title: title, body: body, data: nil, script: nil)
    }

    // MARK: - Assembly

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func page(
        status: Int, title: String, body: String, data: [String: Any]?, script: String?
    ) -> HTTPResponse {
        let nonce = Base64URL.encode(RemoteSecret.bytes(16))
        var dataBlock = ""
        if let data,
            let json = try? JSONSerialization.data(
                withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
        {
            // A data block never runs, but a "</script>" inside it would end
            // it early, so the markup characters stay escaped.
            let safe = String(decoding: json, as: UTF8.self)
                .replacingOccurrences(of: "&", with: "\\u0026")
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
            dataBlock = #"<script type="application/json" id="hc-data">"# + safe + "</script>"
        }
        let scriptBlock = script.map { #"<script nonce="\#(nonce)">"# + sharedScript + $0 + "</script>" } ?? ""
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <meta name="robots" content="noindex">
            <title>\(escape(title)) | Honeycrisp</title>
            <style nonce="\(nonce)">\(styles)</style>
            </head>
            <body>
            <main>
            <p class="mark">Honeycrisp<span>.</span></p>
            \(body)
            <p id="status" role="status"></p>
            </main>
            \(dataBlock)
            \(scriptBlock)
            </body>
            </html>
            """
        let csp = [
            "default-src 'none'",
            "script-src 'nonce-\(nonce)'",
            "style-src 'nonce-\(nonce)'",
            "connect-src 'self'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
        return HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": csp,
                "X-Frame-Options": "DENY",
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
                "Cache-Control": "no-store",
            ],
            body: Data(html.utf8)
        )
    }

    // MARK: - Styles and scripts

    private static let styles = """
        :root { --accent: #C5453A; --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: rgba(0, 0, 0, 0.1); }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #a1a1a6; --line: rgba(255, 255, 255, 0.12); } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
        main { width: 100%; max-width: 420px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 28px; }
        .mark { margin: 0 0 20px; font-size: 17px; font-weight: 600; letter-spacing: -0.03em; color: var(--text); }
        .mark span { color: var(--accent); }
        h1 { margin: 0 0 12px; font-size: 20px; line-height: 1.3; }
        p { margin: 0 0 12px; color: var(--muted); }
        p strong { color: var(--text); overflow-wrap: anywhere; }
        .warn { color: var(--text); background: rgba(197, 69, 58, 0.12); border-radius: 8px; padding: 10px 12px; }
        .actions { display: flex; gap: 10px; margin-top: 20px; }
        button { flex: 1; font: inherit; font-weight: 600; padding: 10px 14px; border-radius: 8px; border: 1px solid var(--line); background: transparent; color: var(--text); cursor: pointer; }
        button.primary { background: var(--accent); border-color: var(--accent); color: #ffffff; }
        button:disabled { opacity: 0.5; cursor: default; }
        #status { min-height: 1.5em; margin: 14px 0 0; }
        """

    private static let sharedScript = """
        const data = JSON.parse(document.getElementById("hc-data").textContent);
        const statusLine = document.getElementById("status");
        const enc = (buffer) => {
          let text = "";
          for (const byte of new Uint8Array(buffer)) text += String.fromCharCode(byte);
          return btoa(text).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
        };
        const dec = (text) => {
          const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
          return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
        };
        const post = async (path, body) => {
          const response = await fetch(path, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
          });
          return response.json();
        };

        """

    private static let consentScript = """
        const buttons = [document.getElementById("allow"), document.getElementById("deny")];
        const busy = (on) => buttons.forEach((button) => { button.disabled = on; });
        const finish = async (body) => {
          busy(true);
          try {
            const result = await post("/authorize", body);
            if (result.redirect) {
              window.location.assign(result.redirect);
              return;
            }
            statusLine.textContent = result.error_description || "Honeycrisp couldn't finish connecting.";
          } catch (error) {
            statusLine.textContent = "Honeycrisp didn't answer. Check that it's running and try again.";
          }
        };
        document.getElementById("allow").addEventListener("click", async () => {
          busy(true);
          statusLine.textContent = "";
          let credential;
          try {
            credential = await navigator.credentials.get({
              publicKey: {
                challenge: dec(data.challenge),
                rpId: data.rpId,
                allowCredentials: data.allow.map((id) => ({ type: "public-key", id: dec(id) })),
                userVerification: "required",
                timeout: 120000,
              },
            });
          } catch (error) {
            statusLine.textContent = "The passkey sign-in didn't finish. You can try again.";
            busy(false);
            return;
          }
          await finish({
            request: data.request,
            approve: true,
            credential: {
              id: enc(credential.rawId),
              clientDataJSON: enc(credential.response.clientDataJSON),
              authenticatorData: enc(credential.response.authenticatorData),
              signature: enc(credential.response.signature),
            },
          });
        });
        document.getElementById("deny").addEventListener("click", () => finish({ request: data.request, approve: false }));
        """

    private static let setupScript = """
        const create = document.getElementById("create");
        create.addEventListener("click", async () => {
          create.disabled = true;
          statusLine.textContent = "";
          let credential;
          try {
            credential = await navigator.credentials.create({
              publicKey: {
                challenge: dec(data.challenge),
                rp: { id: data.rpId, name: "Honeycrisp" },
                user: { id: dec(data.userId), name: "honeycrisp", displayName: "Honeycrisp" },
                pubKeyCredParams: [{ type: "public-key", alg: -7 }],
                authenticatorSelection: { residentKey: "preferred", userVerification: "required" },
                attestation: "none",
                excludeCredentials: data.exclude.map((id) => ({ type: "public-key", id: dec(id) })),
                timeout: 300000,
              },
            });
          } catch (error) {
            statusLine.textContent = "The passkey wasn't created. You can try again.";
            create.disabled = false;
            return;
          }
          try {
            const result = await post("/setup", {
              code: data.code,
              credential: {
                id: enc(credential.rawId),
                clientDataJSON: enc(credential.response.clientDataJSON),
                attestationObject: enc(credential.response.attestationObject),
              },
            });
            if (result.ok) {
              document.querySelector("h1").textContent = "Passkey saved";
              statusLine.textContent = "You can close this page and connect a client.";
              create.remove();
              return;
            }
            statusLine.textContent = result.error_description || "Honeycrisp couldn't save that passkey.";
          } catch (error) {
            statusLine.textContent = "Honeycrisp didn't answer. Check that it's running and try again.";
          }
        });
        """
}
