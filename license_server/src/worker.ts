import { KeyRing } from "./keys.js";
import { LicenseIssuer } from "./licenseIssuer.js";
import { D1LicenseStore } from "./store_d1.ts";
import { FakePlayVerifier, GooglePlayVerifier } from "./playVerifier.js";
import { isKnownProductId, maxTierForOwned } from "./entitlement.js";

export interface Env {
  DB: any;
  LICENSE_PRIVATE_KEY?: string;
  LICENSE_PUBLIC_KEY?: string;
  LICENSE_ACTIVE_KID?: string;
  PLAY_VERIFY_MODE?: string;
  GOOGLE_SERVICE_ACCOUNT_JSON?: string;
  ALLOWED_PACKAGE_NAMES?: string;
}

const DEFAULT_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7Vv9b+8TFbHpH
EH3F3s4nHClJDI6yh+NbHRoCmFnaK52+QTo7xsSatN90P5/Dbv/ly6qJboOHZgI2
LQ5GbS+b1LNWttOlb0eAHnCv65zxXpXtm84anOVobXv3ilfME3EvwAG3LKMGKVTz
a0QQzxr85JsTFceOftuY7ctyH1vFMcaDdS8lw5kO5pxqtRi7AXNNJ9BFngV+c/Dx
oP76+szjRsQ6dLJ1prJSiSEHkhIJSZzhVqqt6dwCI/gmzH+24pjxQC0BhWMyhi8S
19oV0NMLiixJcK51uF0Eafa5Sq6uGLTulvJ1pwoeBmDGfWp6JRiyAazEXBw05bfW
MdWJ70hTAgMBAAECggEAIYoIu5oOd13dYl2kdslV1RCon4hc/79uR8ClCHPoGjQW
0Jny6ALE7gGVw8UkQCPeMnDM/j/H0nTDzpkwZhFkJZzl4o9mwsZyYZCRkh03gsrx
QpHTS1Zth82aFQ4ye7m7WNYiOH4ITbEWoWHB1NSPO1leHgOXL36sp+tisfLFRj88
z/sK/qWb2F0rZEG+w0PgcSSZebBNiaus8z+8hIAiY7wQXbURyRZq3K2RQI/PJJ+0
PDHVcKB3pUKPvq2hDNPBJ/lYqzUmbMwjiyEN66k9FQrVcyotG2kNujbjju0Sgqrx
xJCHD21ndoAQ38nnj+KUMiMvoo95i9VHBPKrLenAEQKBgQD9ZYAYWpGswtY95dW5
NniNr1znX0818HpSnHszsCImwNLBkCrgk89jt9Xcsdpu7JiBjcTN2waTIh9dU0kU
xA0lIqKM/hd3DljWmvVoqGHVhaLeVCJCYy2aB+j/QQjVUEny+OU3fP00dMzLjmpd
Me1Sj00M/+TWVc0KY/ToGWnGewKBgQC9Q8At0b/SYIIBwgyrJDZtomU+Eu6g6BUC
ZTD4bigdjT8N0dCEtKZeWvrgtRYCib7bDOtDH0Fy3EK5Cj+h9zOqlAVyWztxFZyX
mycKUWosiVS3DzaiPFfmJwPiayyLXrE6MSp2Q9GtmpKuxaO/HCQMSglZ+YFJEnYy
NW+Q79uKCQKBgBKe8trXTP01FClYSmxh5FoFGP6nslp0YYjQlv0lZF0Urmgq//ug
4Qyi5cRiDXs5R7u9f0jhX4pQZ52kESrFfXHNKcTSp0bIdx7OJFqchRP7zgwogpv+
TcuT6TtYvB1w2P5R7AY32SORsbsDrC1NDfOTNEZQR7C4fWjWD5k+xNchAoGANQHr
qimLsu0qnDlv+OK8h7oq5tbAlLpLYA9dRsb7X0N2/HTeFLzPt699gj/VeUKA/LLC
lVsEppm/6jlPlxo4Ezc/y0Z4AHUQFXnz1jT1KqIP4vFU2N1TtPcKZHil0ibkNisc
/GCEMj4PhPl/of/MrNBzjAqQRhnwlqFWrN4wu5kCgYEA7Ye2xmbfNHmQyI1lus7V
CqMBRHBYOelfHyM3KRF9IkoSNiKHSnO2QS49RgJNR1Vm8lnPXDyW6hljqy+6cFPz
0vEIgOe0W50GArRndIVUH7ltGbylZVn6fHz0mk+ncAbsM2A9XAmFQg0ilUr05QkH
oggl3X1iI/JzQOd00u5lvUM=
-----END PRIVATE KEY-----`;

const DEFAULT_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu1b/W/vExWx6RxB9xd7O
JxwpSQyOsofjWx0aAphZ2iudvkE6O8bEmrTfdD+fw27/5cuqiW6Dh2YCNi0ORm0v
m9SzVrbTpW9HgB5wr+uc8V6V7ZvOGpzlaG1794pXzBNxL8ABtyyjBilU82tEEM8a
/OSbExXHjn7bmO3Lch9bxTHGg3UvJcOZDuacarUYuwFzTSfQRZ4FfnPw8aD++vrM
40bEOnSydaayUokhB5ISCUmc4VaqrencAiP4Jsx/tuKY8UAtAYVjMoYvEtfaFdDT
C4osSXCudbhdBGn2uUqurhi07pbydacKHgZgxn1qeiUYsgGsxFwcNOW31jHVie9I
UwIDAQAB
-----END PUBLIC KEY-----`;

const DEFAULT_KID = "aurora-20260725";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    const json = (data: any, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: { "Content-Type": "application/json" },
      });

    // GET /v1/health
    if (request.method === "GET" && path === "/v1/health") {
      return json({
        status: "ok",
        uptimeSeconds: Math.floor(performance.now() / 1000),
        time: new Date().toISOString(),
      });
    }

    // GET /v1/ready
    if (request.method === "GET" && path === "/v1/ready") {
      return json({
        status: "ready",
        activeKid: env.LICENSE_ACTIVE_KID || DEFAULT_KID,
      });
    }

    // Setup key ring
    const kid = env.LICENSE_ACTIVE_KID || DEFAULT_KID;
    const privateKeyPem = env.LICENSE_PRIVATE_KEY || DEFAULT_PRIVATE_KEY;
    const publicKeyPem = env.LICENSE_PUBLIC_KEY || DEFAULT_PUBLIC_KEY;

    const keyRing = KeyRing.fromKeys(
      [{ kid, privateKeyPem, publicKeyPem }],
      kid
    );

    // GET /v1/.well-known/jwks.json
    if (request.method === "GET" && path === "/v1/.well-known/jwks.json") {
      return new Response(JSON.stringify(keyRing.toJwks()), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": "public, max-age=3600",
        },
      });
    }

    // Initialize D1 store
    const store = new D1LicenseStore(env.DB);
    const verifier = new FakePlayVerifier();
    const issuer = new LicenseIssuer(keyRing, {
      issuer: "aurora-license",
      audience: "aurora-app",
      ttlSeconds: 30 * 86400,
    });

    const allowedPackages = (
      env.ALLOWED_PACKAGE_NAMES || "com.personal.aurora_downloader"
    ).split(",");

    // POST /v1/license/activate
    if (request.method === "POST" && path === "/v1/license/activate") {
      try {
        const body: any = await request.json();
        const { packageName, installId, purchaseToken, productId, purchases } = body;

        if (!packageName || !allowedPackages.includes(packageName)) {
          return json({ error: "package_not_allowed", message: "Package not allowed" }, 403);
        }

        const items: Array<{ productId: string; purchaseToken: string }> = [...(purchases || [])];
        if (purchaseToken && productId) {
          items.push({ productId, purchaseToken });
        }

        if (items.length === 0) {
          return json({ error: "invalid_request", message: "No purchase tokens provided" }, 400);
        }

        const now = new Date();
        for (const item of items) {
          if (!isKnownProductId(item.productId)) {
            return json({ error: "unknown_product", message: `Unknown productId ${item.productId}` }, 400);
          }
          const verified = await verifier.verify({
            packageName,
            productId: item.productId,
            purchaseToken: item.purchaseToken,
          });
          await store.upsertPurchase({
            purchaseToken: item.purchaseToken,
            productId: item.productId,
            packageName,
            orderId: verified.orderId,
            purchaseState: verified.purchaseState,
            owned: verified.owned,
            now,
          });
          await store.linkInstall(installId, item.purchaseToken, now);
        }

        const activePurchases = await store.listPurchasesForInstall(installId);
        const ownedProducts = activePurchases.map((p) => p.productId);
        const tier = maxTierForOwned(ownedProducts);

        if (tier === "free") {
          return json({ error: "no_valid_purchase", message: "No active entitlements owned" }, 403);
        }

        const license = issuer.issue({
          installId,
          packageName,
          tier,
          products: ownedProducts,
          now,
        });

        await store.recordIssuedLicense({
          jti: license.jti,
          installId,
          tier,
          issuedAt: license.issuedAt.toISOString(),
          expiresAt: license.expiresAt.toISOString(),
        });

        return json({
          license: license.token,
          tier: license.tier,
          products: license.products,
          keyId: license.kid,
          issuedAt: license.issuedAt.toISOString(),
          expiresAt: license.expiresAt.toISOString(),
        });
      } catch (err: any) {
        return json({ error: "internal_error", message: err.message || "Internal error" }, 500);
      }
    }

    // POST /v1/license/refresh
    if (request.method === "POST" && path === "/v1/license/refresh") {
      try {
        const body: any = await request.json();
        const { packageName, installId } = body;

        if (!packageName || !allowedPackages.includes(packageName)) {
          return json({ error: "package_not_allowed", message: "Package not allowed" }, 403);
        }

        const activePurchases = await store.listPurchasesForInstall(installId);
        if (activePurchases.length === 0) {
          return json({ error: "unknown_install", message: "Unknown install" }, 404);
        }

        const ownedProducts = activePurchases.map((p) => p.productId);
        const tier = maxTierForOwned(ownedProducts);

        const now = new Date();
        const license = issuer.issue({
          installId,
          packageName,
          tier,
          products: ownedProducts,
          now,
        });

        return json({
          license: license.token,
          tier: license.tier,
          products: license.products,
          keyId: license.kid,
          issuedAt: license.issuedAt.toISOString(),
          expiresAt: license.expiresAt.toISOString(),
        });
      } catch (err: any) {
        return json({ error: "internal_error", message: err.message || "Internal error" }, 500);
      }
    }

    return json({ error: "not_found", message: "No such endpoint" }, 404);
  },
};
