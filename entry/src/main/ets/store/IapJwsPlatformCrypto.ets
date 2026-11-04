import { cert } from '@kit.DeviceCertificateKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DEBUG } from 'BuildProfile';
import { decodeBase64, encodeBase64, IapJwsCrypto, IapJwsPolicy } from './IapJwsVerifier';

const TAG: string = '[IapJws]';

// Huawei IAP signing root for NORMAL (production) purchases, base64 DER.
// Pending: capture it from a real purchase's x5c chain (debug builds log the
// chain below), confirm it against Huawei's published root, then paste it here.
// While this list is empty, production purchases fail closed: they are never
// unlocked from data whose chain could not be checked.
const HUAWEI_IAP_ROOT_CERTIFICATES_BASE64: string[] = [];

async function parseCertificate(der: Uint8Array): Promise<cert.X509Cert> {
  return cert.createX509Cert({ data: der, encodingFormat: cert.EncodingFormat.FORMAT_DER });
}

class PlatformIapJwsCrypto implements IapJwsCrypto {
  async verifyEs256(leafCertificateDer: Uint8Array, signingInput: Uint8Array,
    derSignature: Uint8Array): Promise<boolean> {
    try {
      const leaf = await parseCertificate(leafCertificateDer);
      // Never pass leaf.getPublicKey() to Verify.init: that key object belongs
      // to the certificate framework, and the crypto framework's native CFI
      // check aborts the whole process on it (SIGABRT, not a catchable error;
      // Pura X 7.0.0.111, 2026-11-04, right after a sandbox purchase). Only
      // bytes cross the boundary: SubjectPublicKeyInfo DER -> convertKey.
      const publicKeyDer = leaf.getItem(cert.CertItemType.CERT_ITEM_TYPE_PUBLIC_KEY);
      const keyPair = await cryptoFramework.createAsyKeyGenerator('ECC256')
        .convertKey({ data: publicKeyDer.data }, null);
      const verifier = cryptoFramework.createVerify('ECC256|SHA256');
      await verifier.init(keyPair.pubKey);
      return await verifier.verify({ data: signingInput }, { data: derSignature });
    } catch (_error) {
      return false;
    }
  }

  async validateChain(chainDer: Uint8Array[], rootCertificatesDer: Uint8Array[]): Promise<boolean> {
    try {
      const certificates: cert.X509Cert[] = [];
      for (let i = 0; i < chainDer.length; i++) {
        certificates.push(await parseCertificate(chainDer[i]));
      }
      const anchors: cert.X509TrustAnchor[] = [];
      for (let i = 0; i < rootCertificatesDer.length; i++) {
        anchors.push({ CACert: await parseCertificate(rootCertificatesDer[i]) });
      }
      // Validation checks every signature, validity window and CA constraint
      // from the leaf up to one of the embedded anchors.
      const chain = cert.createX509CertChain(certificates);
      await chain.validate({ trustAnchors: anchors });
      return true;
    } catch (_error) {
      return false;
    }
  }
}

let platformCrypto: PlatformIapJwsCrypto | undefined = undefined;

export function platformIapJwsCrypto(): IapJwsCrypto {
  if (platformCrypto === undefined) {
    platformCrypto = new PlatformIapJwsCrypto();
  }
  return platformCrypto;
}

export function platformIapJwsPolicy(): IapJwsPolicy {
  const roots: Uint8Array[] = [];
  for (let i = 0; i < HUAWEI_IAP_ROOT_CERTIFICATES_BASE64.length; i++) {
    roots.push(decodeBase64(HUAWEI_IAP_ROOT_CERTIFICATES_BASE64[i]));
  }
  const policy: IapJwsPolicy = { allowSandbox: DEBUG, rootCertificatesDer: roots };
  if (DEBUG) {
    policy.observeChain = (chainDer: Uint8Array[]): void => {
      if (!chainLogged) {
        chainLogged = true;
        void logIapCertificateChainForDebug(chainDer);
      }
    };
  }
  return policy;
}

let chainLogged: boolean = false;

/**
 * Debug builds only: print the public x5c certificates so the production root
 * can be identified and embedded. Certificates are public data; purchase
 * payloads and tokens are never logged.
 */
export async function logIapCertificateChainForDebug(chainDer: Uint8Array[]): Promise<void> {
  if (!DEBUG) {
    return;
  }
  for (let i = 0; i < chainDer.length; i++) {
    try {
      const parsed = await parseCertificate(chainDer[i]);
      const subject = parsed.getSubjectX500DistinguishedName().getName();
      const issuer = parsed.getIssuerX500DistinguishedName().getName();
      console.info(`${TAG} x5c[${i}] subject=${subject} issuer=${issuer} notAfter=${parsed.getNotAfterTime()}`);
    } catch (_error) {
      console.info(`${TAG} x5c[${i}] unparsable`);
    }
    const encoded = encodeBase64(chainDer[i]);
    // hilog truncates long lines, so the DER is split into numbered pieces.
    for (let offset = 0; offset < encoded.length; offset += 800) {
      console.info(`${TAG} x5c[${i}] der#${offset / 800}=${encoded.substring(offset, offset + 800)}`);
    }
  }
}
