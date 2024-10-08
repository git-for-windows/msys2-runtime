# Makefile for Cygwin utilities

# This file is part of Cygwin.

# This software is a copyrighted work licensed under the terms of the
# Cygwin license.  Please consult the file "CYGWIN_LICENSE" for
# details.

# We put utilities built with a MinGW compiler in a separate Makefile here
# because it's tricky with Automake to use different compilers for the same
# language in the same Makefile.

override CXX = @MINGW_CXX@
AM_CPPFLAGS =

include $(top_srcdir)/Makefile.am.common

CFLAGS_COMMON=-Wimplicit-fallthrough=4 -Werror -D_WIN32_WINNT=0x0a00 -DNTDDI_VERSION=WDK_NTDDI_VERSION
AM_CXXFLAGS=-fno-exceptions -fno-rtti -fno-use-cxa-atexit $(flags_common) $(CFLAGS_COMMON)

AM_LDFLAGS = -static

bin_PROGRAMS = \
	cygcheck \
	cygwin-console-helper \
	ldh \
	strace

libexec_PROGRAMS = getprocaddr32 getprocaddr64

# Must *not* use -O2 here, as it screws up the stack backtrace
getprocaddr32.o: %32.o: %.c
	$(MINGW32_CC) -c -o $@ $<

getprocaddr32.exe: %.exe: %.o
	$(MINGW32_CC) -o $@ $^ -static -ldbghelp

getprocaddr64.o: %64.o: %.c
	$(MINGW64_CC) -c -o $@ $<

getprocaddr64.exe: %.exe: %.o
	$(MINGW64_CC) -o $@ $^ -static -ldbghelp

cygcheck_SOURCES = \
	bloda.cc \
	cygcheck.cc \
	dump_setup.cc \
	path.cc
cygcheck_CPPFLAGS=-I$(srcdir)/.. -idirafter ${top_srcdir}/cygwin/include
cygcheck_LDFLAGS = ${AM_LDFLAGS} -Wl,--disable-high-entropy-va
cygcheck_LDADD = -lz -lwininet -lshlwapi -lpsapi -lntdll

cygwin_console_helper_SOURCES = cygwin-console-helper.cc

ldh_SOURCES = ldh.cc
ldh_LDFLAGS = ${AM_LDFLAGS} -Wl,--disable-high-entropy-va

strace_SOURCES = \
	path.cc \
	strace.cc
strace_CPPFLAGS=-I$(srcdir)/.. -idirafter ${top_srcdir}/cygwin/local_includes -idirafter ${top_srcdir}/cygwin/include
strace_LDFLAGS = ${AM_LDFLAGS} -Wl,--disable-high-entropy-va
strace_LDADD = -lntdll

noinst_PROGRAMS = path-testsuite

path_testsuite_SOURCES = \
	path.cc \
	testsuite.cc
path_testsuite_CPPFLAGS=-I$(srcdir)/.. -idirafter ${top_srcdir}/cygwin/include
path_testsuite_CXXFLAGS = -DTESTSUITE

TESTS = path-testsuite
