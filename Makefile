#
#  These three macros should be defined by user
#
WORKQ_FILE = /tmp/workQueue.${USER}

# JesseB added these three lines (which will remain different from the PReach repo's Makefile)
# to support Intel's world-useable PReach (is there a better way to do this?)
PREACH_ROOT = /p/dt/fvcoe/pub/tools/PReach/preach/
ERLANG_PREFIX = /p/dt/fvcoe/pub/
ERL_INTERFACE_VERSION = erl_interface-3.7.7

# -W0 turns off warnings here... 
# remove +native if you want accurate stack dumps from the Erlang Runtime System
ERLC_OPTIONS = +\{hipe,\[o3\]\} 
#ERLC_OPTIONS = +debug_info 
MURPHI_INCLUDE = ${PREACH_ROOT}/MurphiEngine/include
# for UBC:

ERLANG_INTERFACE_INCLUDE = ${ERLANG_PREFIX}/lib/erlang/lib/${ERL_INTERFACE_VERSION}/include
ERLANG_INTERFACE_LIBS = ${ERLANG_PREFIX}/lib/erlang/lib/${ERL_INTERFACE_VERSION}/lib
ERLANG_ERTS_INCLUDE = ${ERLANG_PREFIX}/lib/erlang/usr/include
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

preach.beam: preach.erl 
	erlc $(ERLC_OPTIONS) $<
	chmod a+r $@

%.beam: %.erl
	erlc $(ERLC_OPTIONS) $<
	chmod a+r $@

# choice of compiler (with REQUIRED options)
#GCC=g++   # -O3 core dumps occasionally
#GCC = /usr/intel/pkgs/gcc/4.5.0/bin/g++
GCC = g++
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
	echo "if RULES_IN_WORLD below is bigger than 5000, you're probably exceeding the capacity of PReach:"
	grep RULES_IN_WORLD $@

%.so: %.C ${PREACH_ROOT}/MurphiEngine/include/*
	$(GCC) -O2 -DERLANG -DCATCH_DIV -Wno-write-strings -Wno-deprecated -g -lm  -o $@ -fpic -shared $<  \
	-I${MURPHI_INCLUDE} \
	-I${ERLANG_INTERFACE_INCLUDE} \
	-I${ERLANG_ERTS_INCLUDE} \
	-L${ERLANG_INTERFACE_LIBS} -lei -lerl_interface

murphiengine:
	cd MurphiEngine/src; make

