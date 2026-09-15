# The EIF is built from this image. Two things to know before you touch it:
#
#  1. Image size drives enclave boot time almost linearly. Every MB you add
#     shows up on every cold start. Keep it lean.
#  2. Changing ANY line here changes PCR0, which invalidates your KMS key
#     policy. Rebuild, get AccessDenied, wonder why for an hour. Pin bases by
#     digest before you write the policy.

FROM amazonlinux:2023

RUN dnf install -y python3 python3-pip \
    && pip3 install --no-cache-dir cryptography==43.0.1 \
    && dnf clean all && rm -rf /var/cache/dnf

WORKDIR /app

# Optional: attestation-gated KMS. Build the binary once, out of band:
#   git clone --depth 1 https://github.com/aws/aws-nitro-enclaves-sdk-c
#   cd aws-nitro-enclaves-sdk-c
#   docker build -t kmstool -f containers/Dockerfile.al2 .
#   docker run --rm --entrypoint cat kmstool /kmstool_enclave_cli \
#       > enclave/bin/kmstool_enclave_cli && chmod +x enclave/bin/*
# Leave bin/ empty and run with DEV_MODE=1 while you are only timing things.
COPY enclave/bin/ /app/

COPY common/ /app/common/
COPY enclave/app.py /app/enclave/app.py

ENV TRANSPORT=vsock ENCLAVE_PORT=5005 PYTHONUNBUFFERED=1
CMD ["python3", "/app/enclave/app.py"]
