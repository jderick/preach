#
#  These three macros should be defined by user
#
WORKQ_FILE = /tmp/workQueue.${USER}

# -W0 turns off warnings here... 
# remove +native if you want accurate stack dumps from the Erlang Runtime System
ERLC_OPTIONS = +native  +\{hipe,\[o3\]\} +debug_info 
MURPHI_INCLUDE = ${PREACH_ROOT}/MurphiEngine/include
ERLANG_INCLUDE = ${ERLANG_ROOT}/lib/erl_interface/include
ERLANG_INTERFACE_OBJS = ${ERLANG_ROOT}/lib/erl_interface/obj/x86_64-unknown-linux-gnu
MU=${PREACH_ROOT}/MurphiEngine/src/mu
BEAMS = bitarray.beam bloom.beam murphi_interface.beam diskfilter.beam diskq.beam preach.beam

#all: compile
all: ${BEAMS} murphiengine

.PHONY compile:
	@erl -make

clean: 
	rm -f *.beam
	rm -f erl_crash.dump

run:
	if [ -w ${WORKQ_FILE} ]; then rm ${WORKQ_FILE}; fi
	for i in `ls -1 /tmp/tracefile_${USER}.dqs*`; do\
		if [ -O $$i ]; then rm $$i; fi done	
	PREACH_TIMESTAMP=`date +%s` erl -localmode -sname console +h 1000000

preach.beam: preach.erl common.erl
	erlc $(ERLC_OPTIONS) $<

%.beam: %.erl
	erlc $(ERLC_OPTIONS) $<


# Author:               Ulrich Stern
# Version:              1
# Creation Date:        Sat May 25 15:13:39 PDT 1996
# Filename:             Makefile
# History:
#
# Experiences compiling the Murphi verifier:
#  There are two things that caused problems in this Muphi release:
#  - Some compilers - especially those based on cfront - can only generate
#   very simple inline code. One has to turn off inlining in this case. The
#   options are typically +d (CC, OCC, DCC) or -fno-default-inline (g++).
#   The compilation is much faster then as well.
#  - The "signal" system call used in Murphi for defining an own handler
#   to catch division by zero seems to be system dependent. Two different
#   ways to use this call can be selected by defining or not-defining
#   CATCH_DIV. See below for when defining CATCH_DIV was needed.

# path for including mu_verifier.C etc.

# Murphi compiler

# choice of compiler (with REQUIRED options)
GCC=g++   # -O3 core dumps occasionally
OFLAGS=-O2

# options (really OPTIONAL)
CFLAGS=-Wno-deprecated -DCATCH_DIV 

# optimization

#GCC=icc 
#OFLAGS=-tpp7 -O3 -ipo -unroll4
#OFLAGS=
#CFLAGS=-Wno-deprecated -DCATCH_DIV -static

# rules for compiling

#%.log: %.exe 
#	touch $@
#	mv $@ $@.OLD
#	mkdir -p /tmp/`basename ${PWD}`
#	./$< -m 12000 -p6 -sym1 -tv -d /tmp/`basename ${PWD}` 

%.C: %.m 
	${MU} -c -b $<

%.so: %.C ${PREACH_ROOT}/MurphiEngine/include/*
	g++ -DERLANG -DCATCH_DIV -Wno-write-strings -Wno-deprecated -g -lm  -o $@ -fpic -shared $<  \
	-I${ERLANG_ROOT}/erts/emulator/beam \
	-I${ERLANG_ROOT}/lib/erlang/usr/include/ \
	-I${MURPHI_INCLUDE} -I${ERLANG_INCLUDE} -L${ERLANG_INTERFACE_OBJS} -lei -lerl_interface

murphiengine:
	cd MurphiEngine/src; make

