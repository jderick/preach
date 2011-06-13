#
#  These three macros should be defined by user
#
WORKQ_FILE = /tmp/workQueue.${USER}

# -W0 turns off warnings here... 
# remove +native if you want accurate stack dumps from the Erlang Runtime System
ERLC_OPTIONS = +\{hipe,\[o3\]\} 
#ERLC_OPTIONS = +debug_info 
MURPHI_INCLUDE = ${PREACH_ROOT}/MurphiEngine/include
# for UBC:
# ERLANG_INTERFACE_INCLUDE = ${ERLANG_PREFIX}/lib/erlang/lib/erl_interface-3.6.2/include
# ERLANG_INTERFACE_LIBS = ${ERLANG_PREFIX}/lib/erlang/lib/erl_interface-3.6.2/lib

ERLANG_INTERFACE_INCLUDE = ${ERLANG_PREFIX}/lib/erlang/lib/erl_interface-3.6.3/include
ERLANG_INTERFACE_LIBS = ${ERLANG_PREFIX}/lib/erlang/lib/erl_interface-3.6.3/lib
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

%.beam: %.erl
	erlc $(ERLC_OPTIONS) $<

# choice of compiler (with REQUIRED options)
#GCC=g++   # -O3 core dumps occasionally
GCC = /usr/intel/pkgs/gcc/4.5.0/bin/g++
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
	$(GCC) -O2 -DERLANG -DCATCH_DIV -Wno-write-strings -Wno-deprecated -g -lm  -o $@ -fpic -shared $<  \
	-I${MURPHI_INCLUDE} \
	-I${ERLANG_INTERFACE_INCLUDE} \
	-I${ERLANG_ERTS_INCLUDE} \
	-L${ERLANG_INTERFACE_LIBS} -lei -lerl_interface

murphiengine:
	cd MurphiEngine/src; make

