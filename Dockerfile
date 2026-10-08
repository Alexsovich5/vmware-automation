FROM mcr.microsoft.com/powershell:6.0.4-ubuntu-trusty-20180807

ENV TEMP=/tmp

RUN pwsh -NoProfile -NonInteractive -Command " \
    \$ErrorActionPreference = 'Stop'; \
    \$ProgressPreference = 'SilentlyContinue'; \
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; \
    \$zip = '/tmp/pester-2.0.4.zip'; \
    Invoke-WebRequest -Uri 'https://github.com/pester/Pester/archive/2.0.4.zip' -OutFile \$zip -UseBasicParsing; \
    \$hash = (Get-FileHash -Path \$zip -Algorithm SHA256).Hash.ToLower(); \
    if (\$hash -ne 'c880803480d577e1e10c899fc56e91aba361ce09c4799d355f74a319eaecbf89') { throw ('Pester archive SHA256 mismatch: ' + \$hash) }; \
    Expand-Archive -Path \$zip -DestinationPath /opt; \
    Remove-Item \$zip; \
    if (-not (Test-Path /opt/Pester-2.0.4/Pester.psm1)) { throw 'Pester.psm1 not found after extraction' } \
    "

WORKDIR /work
