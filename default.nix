{ nixpkgs ? builtins.fetchTarball {
    url = "https://github.com/nixos/nixpkgs/archive/58dae9ca1c2c52990e45f358b680e8411a9dfab1.tar.gz";
  }
, system ? builtins.currentSystem
}:
import nixpkgs {
  inherit system;
  crossSystem = {
    libc = "musl";
    config = "mips-unknown-linux-musl";
    openssl.system = "linux-generic32";
    withTLS = true;

    name = "ath79"; # idk
    linux-kernel = {
      name = "ath79";
      target = "uImage";
      installTarget = "uImage";
      autoModules = false;
    };
  };
  config.allowUnsupportedSystem = true;
  overlays = [(self: super: let inherit (self) lib; in {
    openwrt-src = builtins.fetchGit {
      url = https://git.openwrt.org/openwrt/openwrt.git;
      rev = "cbfce9236754700a343632fff8e035acbc1b1384";
    };

    initramfs = super.makeInitrd {
      compressor = "${self.pkgsBuildHost.zstd}/bin/zstd";
      makeUInitrd = true;
      contents = [{
        object = (super.buildEnv {
          name = "uap-nix-bin";
          paths = [
            self.busybox
            self.hostapd
            self.iw
            (super.writeScriptBin "reset-wifi" ''
              #!/bin/sh
              cd /sys/bus/pci/drivers/ath10k_pci
              echo 0000:00:00.0 > unbind
              echo 0000:00:00.0 > bind
            '')
            (super.writeScriptBin "debug-wifi" ''
              #!/bin/sh
              echo 0xffffffff > /sys/module/ath10k_core/parameters/debug_mask
              echo 8 > /proc/sys/kernel/printk
              cd /sys/bus/pci/drivers/ath10k_pci
              echo 0000:00:00.0 > unbind
              echo 0000:00:00.0 > bind
            '')
            (super.writeScriptBin "cal-wifi" ''
              #!/bin/sh
              mtd=$(grep '"art"' /proc/mtd | cut -d : -f 1)
              dd if=/dev/$mtd of=/lib/firmware/ath10k/cal-pci-0000:00:00.0.bin iflag=skip_bytes,fullblock bs=$((0x844)) skip=$((0x5000)) count=1
            '')
            (lib.hiPrio (super.writeScriptBin "reboot" ''
              #!/bin/sh
              echo b > /proc/sysrq-trigger
            ''))
          ];
          pathsToLink = ["/bin"];
        }) + "/bin";
        symlink = "/bin";
      } {
        object = super.writeScript "init" ''
          #!/bin/sh
          set -x
          mount -t devtmpfs none /dev
          mount -t proc proc /proc
          mount -t sysfs sys /sys
          mkdir -p /run
          mount -t tmpfs tmpfs /run
          ip l set eth0 up
          cal-wifi
          reset-wifi
          sleep 3 # hackhack
          ip l set wlan0 up
          iw dev wlan0 scan >/dev/null
          hostapd /etc/hostapd.conf &
          exec sh
        '';
        symlink = "/init";
      } {
        object = super.runCommandNoCC "firmware-ath10k" {} ''
          mkdir -p $out/ath10k
          cp -r ${self.firmwareLinuxNonfree}/lib/firmware/ath10k/QCA988X $out/ath10k/
          cp -r ${self.wireless-regdb}/lib/firmware/* $out/
        '';
        symlink = "/lib/firmware";
      } {
        object = super.writeText "hostapd.conf" ''
          interface=wlan0
          hw_mode=a
          ssid=uap-nix
          country_code=DE
          ieee80211h=1
          ieee80211n=1
          ieee80211ac=1
          ieee80211d=1
          driver=nl80211
          wmm_enabled=1
          auth_algs=1
          wpa=2
          wpa_key_mgmt=WPA-PSK
          rsn_pairwise=CCMP
          wpa_passphrase=abcdefgh
          channel=36
        '';
        symlink = "/etc/hostapd.conf";
      } ];
    };

    lib = super.lib // {
      elementsInDir = dir: lib.mapAttrsToList (name: type: { inherit type name; path = dir + "/${name}"; }) (builtins.readDir dir);
      filesInDir = dir: map ({ path, ... }: path) (super.lib.filter (entry: entry.type == "regular") (lib.elementsInDir dir));
    };

    kernelSrc = (super.applyPatches {
      inherit (self.linux_5_10) src;
      patches = []
      ++ (lib.filesInDir "${self.openwrt-src}/target/linux/generic/backport-5.10")
      ++ (lib.filesInDir "${self.openwrt-src}/target/linux/generic/pending-5.10")
      ++ (lib.filesInDir "${self.openwrt-src}/target/linux/ath79/patches-5.10")
      ;
    }).overrideAttrs (o: {
      prePatch = ''
        (
        ${self.pkgsBuildHost.rsync}/bin/rsync -rt ${self.openwrt-src}/target/linux/generic/files/ ./
        ${self.pkgsBuildHost.rsync}/bin/rsync -rt ${self.openwrt-src}/target/linux/ath79/files/ ./
        )
      '';
    });

    kernel = (super.buildLinux {
      inherit (super.linux_5_10) version;
      src = self.kernelSrc;
      defconfig = "ath79_defconfig";
      useCommonConfig = false;
      autoModules = false;
      ignoreConfigErrors = false;
      structuredExtraConfig = with super.lib.kernel; super.lib.mkForce {
        MAGIC_SYSRQ = yes;
        MIPS_RAW_APPENDED_DTB = yes;
        DEVTMPFS = yes;
        TMPFS = yes;

        # Debugging
        IKCONFIG = yes;
        IKCONFIG_PROC = yes;

        SPI_AR934X = yes;

        # Ethernet
        AG71XX = yes;
        #GENERIC_PHY = yes;
        #GENERIC_PINCONF = yes;
        PINCTRL_SINGLE = yes;
        AT803X_PHY = yes;
        REGULATOR = yes;

        #MDIO_GPIO = yes;
        #MDIO_I2C = yes;
        MFD_SYSCON = yes;

        # WiFi
        PCI = yes;
        PCI_AR724X = yes;
        CFG80211 = yes;
        MAC80211 = yes;
        RFKILL = yes;
        ATH_COMMON = yes;
        ATH10K = yes;
        ATH10K_PCI = yes;
        ATH10K_DEBUG = yes;

        # Other
        IPV6 = yes;

        NEW_LEDS = yes;
        LEDS_CLASS = yes;
        LEDS_GPIO = yes;

        # minimalisation
        ATH9K = no;
        RTW88 = no;
        MODULES = yes;
      };
      kernelPatches = [];
    }).overrideAttrs (o: rec {
      installPhase = ''
        mkdir -p $out
        cp -v arch/mips/boot/uImage $out/
        cp -v arch/mips/boot/vmlinu[xz]* $out/
        cp -v vmlinux $out/
      '';
    });

    dtb = super.runCommandCC "uaclite.dtb" { nativeBuildInputs = [ self.pkgsBuildHost.dtc ]; } ''
      unpackFile ${self.kernel.src}
      $CC -E -nostdinc -x assembler-with-cpp -I linux*/include ${self.openwrt-src}/target/linux/ath79/dts/qca9563_ubnt_unifiac-lite.dts -o - | dtc -o $out
    '';

    boot = super.runCommandCC "boot" {
      nativeBuildInputs = [
        self.pkgsBuildHost.ubootTools
        self.pkgsBuildHost.pigz
      ];
    } ''
      set -x
      PS4=' $ '
      mkdir -p $out
      cd $out

      cat ${self.kernel}/vmlinux.bin ${self.dtb} > vmlinux.bin
      pigz -9 vmlinux.bin

      mkimage \
        -A mips \
        -O linux \
        -C gzip \
        -T kernel \
        -a 0x80060000 \
        -n Linux-${self.kernel.version} \
        -d vmlinux.bin.gz \
        $out/kernel.img

      ln -s ${self.initramfs}/initrd.img initramfs.img

      ls -lh $(readlink -f initramfs.img kernel.img)
      set +x
    '';
  })];
}
