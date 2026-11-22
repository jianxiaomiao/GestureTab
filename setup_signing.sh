#!/bin/bash
set -euo pipefail

CERT_NAME="GestureTab Local Signer"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 已存在代码签名证书: $CERT_NAME"
    exit 0
fi

WORK_DIR="/tmp/gesturetab_cert"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

cat > "$WORK_DIR/cert.conf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = v3_codesign
prompt             = no

[ req_distinguished_name ]
CN = $CERT_NAME

[ v3_codesign ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

echo "正在生成本地代码签名证书 ($CERT_NAME)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK_DIR/key.pem" \
  -out "$WORK_DIR/cert.pem" \
  -days 3650 \
  -config "$WORK_DIR/cert.conf"

openssl pkcs12 -export \
  -inkey "$WORK_DIR/key.pem" \
  -in "$WORK_DIR/cert.pem" \
  -out "$WORK_DIR/cert.p12" \
  -passout pass:gesturetab

echo "正在导入证书到登录钥匙串..."
security import "$WORK_DIR/cert.p12" \
  -k "$KEYCHAIN" \
  -P "gesturetab" \
  -T /usr/bin/codesign

echo "正在将证书设为代码签名信任根（如弹出系统密码框请确认）..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

rm -rf "$WORK_DIR"
echo "✅ 本地签名证书配置完成！此后更新编译将不再重置系统权限。"
