# modplug

MODPLUG_VERSION := 0.8.8.4
MODPLUG_URL := $(SF)/modplug-xmms/libmodplug-$(MODPLUG_VERSION).tar.gz

PKGS += modplug
ifeq ($(call need_pkg,"libmodplug >= 0.8.4 libmodplug != 0.8.8"),)
PKGS_FOUND += modplug
endif

$(TARBALLS)/libmodplug-$(MODPLUG_VERSION).tar.gz:
	$(call download,$(MODPLUG_URL))

.sum-modplug: libmodplug-$(MODPLUG_VERSION).tar.gz

libmodplug: libmodplug-$(MODPLUG_VERSION).tar.gz .sum-modplug
	$(UNPACK)
	$(UPDATE_AUTOCONFIG)
	$(call pkg_static,"libmodplug.pc.in")
	$(MOVE)

.modplug: libmodplug
	cd $< && $(HOSTVARS) ./configure $(HOSTCONF)
# TODO: why ./configure can't check HAVE_SETENV & HAVE_SINF to yes in MIPS?
ifeq ($(ARCH),mips)
	cd libmodplug && sed -i.orig "s/\/\* #undef HAVE_SETENV \*\//#define HAVE_SETENV 1/" src/config.h
	cd libmodplug && sed -i.orig "s/\/\* #undef HAVE_SINF \*\//#define HAVE_SINF 1/" src/config.h
endif
	cd $< && $(MAKE) install
	touch $@
