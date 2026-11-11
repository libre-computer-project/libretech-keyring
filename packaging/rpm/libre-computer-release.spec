# libre-computer-release -- the Libre Computer dnf repository and the OpenPGP key that signs it (Fedora: the
# third-party `<vendor>-release` form). Built by build-rpm.sh, which defines lc_version and lc_keyid and puts both
# sources in SOURCES.
Name:           libre-computer-release
Version:        %{lc_version}
Release:        1
Summary:        Libre Computer package repository and signing key
# the repository carries no license file yet; the operator names one
License:        LicenseRef-Not-Specified
URL:            https://packages.libre.computer/
BuildArch:      noarch
Source0:        RPM-GPG-KEY-libre-computer
Source1:        libre-computer.repo
# renamed from libre-computer-repos (published 2026-11-06): a host with it moves on its next upgrade
# (package-parity-policy.md rule 6.5)
Obsoletes:      libre-computer-repos < %{version}-%{release}
Provides:       libre-computer-repos = %{version}-%{release}

%description
The dnf repository definition for https://packages.libre.computer/rpm and the OpenPGP key that
signs its packages and repository metadata.

%install
install -Dpm 0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-libre-computer
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/yum.repos.d/libre-computer.repo

%posttrans
# rpm keeps a key it has already imported: importing a renewed key (same id, new expiry) is a no-op,
# so the stored copy is deleted first. Never fails the transaction.
rpmkeys --delete %{lc_keyid} >/dev/null 2>&1 || :
rpmkeys --import %{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-libre-computer >/dev/null 2>&1 || :

%files
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-libre-computer
%config(noreplace) %{_sysconfdir}/yum.repos.d/libre-computer.repo
