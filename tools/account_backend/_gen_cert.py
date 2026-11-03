import os
import ipaddress
import datetime

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

root = os.path.dirname(os.path.abspath(__file__))
certs = os.path.join(root, "certs")
os.makedirs(certs, exist_ok=True)
key_path = os.path.join(certs, "127.0.0.1-key.pem")
cert_path = os.path.join(certs, "127.0.0.1.pem")

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name(
    [x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")]
)
san = x509.SubjectAlternativeName(
    [
        x509.DNSName("localhost"),
        x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
    ]
)
now = datetime.datetime.utcnow()
cert = (
    x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=3650))
    .add_extension(san, critical=False)
    .sign(key, hashes.SHA256())
)

with open(key_path, "wb") as f:
    f.write(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
with open(cert_path, "wb") as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))

print("wrote", cert_path)
print("wrote", key_path)
