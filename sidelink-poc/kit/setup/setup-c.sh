#!/bin/bash
# New PC (Zorin 18.1 / noble): UHD PPA + OAI sl-release-1.0 @ 53a8ac81 + PoC patch + build. Run: sudo bash setup-c.sh
set -o pipefail
U=${SUDO_USER:?}; R=/home/$U/nr-sl-release-poc; SHA=53a8ac81d17bebff390a16c87384fd6521ac5afd
export DEBIAN_FRONTEND=noninteractive
echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
step() { echo "=== $(date +%T) $*"; }
step prereqs
apt-get update -y >/dev/null
apt-get install -y git build-essential cmake ninja-build pkg-config python3 python3-numpy curl wget ca-certificates \
  software-properties-common usbutils iproute2 iputils-ping iperf3 tcpdump sysstat ethtool linux-tools-common || { echo SETUP_FAILED prereqs; exit 1; }
step UHD
add-apt-repository -y ppa:ettusresearch/uhd || { echo SETUP_FAILED ppa; exit 1; }
apt-get update -y >/dev/null
apt-get install -y libuhd-dev uhd-host || { echo SETUP_FAILED uhd; exit 1; }
uhd_config_info --version | tee $R/logs/uhd-version.txt
uhd_images_downloader -t b2xx | tail -2
step clone
[ -d $R/oai ] || sudo -u $U git clone --branch sl-release-1.0 --single-branch https://gitlab.eurecom.fr/oai/openairinterface5g.git $R/oai || { echo SETUP_FAILED clone; exit 1; }
cd $R/oai && sudo -u $U git checkout --detach $SHA || { echo SETUP_FAILED sha; exit 1; }
step patch
sudo -u $U git diff --quiet && { sudo -u $U git apply $R/logs/local-patch-usrp.patch || { echo SETUP_FAILED patch; exit 1; }; }
sudo -u $U git diff | sha256sum
step "install deps + build (os-release shown as ubuntu in a private mount namespace)"
cat > $R/build-c.sh <<EOS
#!/bin/bash
set -o pipefail
mount --bind $R/os-release-ubuntu /etc/os-release && mount --bind $R/os-release-ubuntu /usr/lib/os-release
cd $R/oai/cmake_targets
./build_oai -I 2>&1 | tee $R/logs/install.txt | tail -3 || { echo SETUP_FAILED install; exit 1; }
sudo -u $U ./build_oai --nrUE -w USRP --ninja -c 2>&1 | tee $R/logs/build.txt | tail -5 || { echo SETUP_FAILED build; exit 1; }
EOS
chown -R $U:$U $R
unshare -m bash $R/build-c.sh || exit 1
cd $R/oai/cmake_targets
test -x ran_build/build/nr-uesoftmodem && test -f ran_build/build/liboai_usrpdevif.so || { echo SETUP_FAILED artifacts; exit 1; }
ldd ran_build/build/liboai_usrpdevif.so | grep -E "uhd|boost_thread"
chown -R $U:$U $R
echo SETUP_DONE
