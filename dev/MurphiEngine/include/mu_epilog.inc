/* -*- C++ -*-
 * mu_epilog.inc
 * @(#) The driver for Murphi verifiers.
 *
 * Copyright (C) 1992 - 1999 by the Board of Trustees of
 * Leland Stanford Junior University.
 *
 * License to use, copy, modify, sell and/or distribute this software
 * and its documentation any purpose is hereby granted without royalty,
 * subject to the following terms and conditions:
 *
 * 1.  The above copyright notice and this permission notice must
 * appear in all copies of the software and related documentation.
 *
 * 2.  The name of Stanford University may not be used in advertising or
 * publicity pertaining to distribution of the software without the
 * specific, prior written permission of Stanford.
 *
 * 3.  This software may not be called "Murphi" if it has been modified
 * in any way, without the specific prior written permission of David L.
 * Dill.
 *
 * 4.  THE SOFTWARE IS PROVIDED "AS-IS" AND STANFORD MAKES NO
 * REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED, BY WAY OF EXAMPLE,
 * BUT NOT LIMITATION.  STANFORD MAKES NO REPRESENTATIONS OR WARRANTIES
 * OF MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE
 * USE OF THE SOFTWARE WILL NOT INFRINGE ANY PATENTS, COPYRIGHTS
 * TRADEMARKS OR OTHER RIGHTS. STANFORD SHALL NOT BE LIABLE FOR ANY
 * LIABILITY OR DAMAGES WITH RESPECT TO ANY CLAIM BY LICENSEE OR ANY
 * THIRD PARTY ON ACCOUNT OF, OR ARISING FROM THE LICENSE, OR ANY
 * SUBLICENSE OR USE OF THE SOFTWARE OR ANY SERVICE OR SUPPORT.
 *
 * LICENSEE shall indemnify, hold harmless and defend STANFORD and its
 * trustees, officers, employees, students and agents against any and all
 * claims arising out of the exercise of any rights under this Agreement,
 * including, without limiting the generality of the foregoing, against
 * any damages, losses or liabilities whatsoever with respect to death or
 * injury to person or damage to property arising from or out of the
 * possession, use, or operation of Software or Licensed Program(s) by
 * LICENSEE or its customers.
 *
 * Read the file "license" distributed with these sources, or call
 * Murphi with the -l switch for additional information.
 * 
 */

/* 
 * Original Author: Ralph Melton
 * 
 * Update:
 *
 * C. Norris Ip
 * Subject: Breakdown into files
 * First modified : 14 Jan 93
 * Last modified : 23 March 93
 *
 * C. Norris Ip 
 * Subject: symmetry syntax
 * First version: Jan 14, 93 -- June 11, 93
 * Transfer to Liveness Version:
 * First modified: November 8, 93
 *
 */ 

/****************************************
  header that depend on constants
  which is generated in the middle of the compiled program:
  RULES_IN_WORLD
  ****************************************/
#include "mu_util_dep.h"

/****************************************
  supporting routines
  ****************************************/
#ifdef HASHC
#include "mu_hash.C"
#endif
#include "mu_util.C"
#include "mu_io.C"
#include "mu_state.C"
#include "mu_system.C"
#include "mu_sym.C"


/****************************************
  main routines
  ****************************************/
#include "mu_verifier.C"

#include <iostream>
#include <sstream>
#include <execinfo.h>

/* preach related crud (next 93 lines or so) */
using namespace std;

extern "C" {

typedef struct {
  ErlDrvPort port;
  StartStateManager* start_states;
  PropertyManager* props;
  char* state_buffer;
  char* erlang_false;
  char* erlang_true;
  int size;
  state_set* brad_hash;
  state_set* cgt_hash;
} example_data;


static ErlDrvData example_drv_start(ErlDrvPort port, char *buff)
{
    example_data* d = (example_data*)driver_alloc(sizeof(example_data));
    d->port = port;
    args = new argclass(0, 0);
    theworld.to_state(NULL);
    StartState = new StartStateManager();
    Rules = new RuleManager();
    Properties = new PropertyManager();

      args->perm_limit.set(5);

    /* there will be some overhead so the true limit is slightly less */
//#define PASS_THIS_MANY_STATES 100
#ifdef PASS_THIS_MANY_STATES
    d->size = RULES_IN_WORLD * BLOCKS_IN_WORLD * PASS_THIS_MANY_STATES; 
#else
    d->size = RULES_IN_WORLD * (BLOCKS_IN_WORLD + 10) +100;  // JESSE: the +10 and +100 are just guesses, but they were John's guesses so they must be right.
#endif
    d->state_buffer = new char[d->size];
    //preachlog = fopen("/netbatch/jdbingha.preachlog","w");

    int i = 0;
    d->erlang_true = new char[1024]; //JESSE: i dunno how big this should be
    ei_encode_version(d->erlang_true, &i);
    ei_encode_atom(d->erlang_true, &i, "true");
    i = 0;
    d->erlang_false = new char[1024]; //JESSE: i dunno how big this should be
    ei_encode_version(d->erlang_false, &i);
    ei_encode_atom(d->erlang_false, &i, "false");

    printf("Murphi Engine booted.\n");fflush(stdout);
    return (ErlDrvData)d;
}


static void example_drv_stop(ErlDrvData handle)
{
  example_data* d = (example_data*)(&handle);
  //delete(d->start_states);
  //delete(Rules);
  //delete(Properties);
  //delete(d->state_buffer);
  driver_free((char*)handle);
}

static void example_drv_output(ErlDrvData handle, char *buff, int bufflen)
{
    example_data* d = (example_data*)handle;
    char fn = buff[0], arg = buff[1], res;

    if (fn == 14) {
        //int start_time = clock();
#ifndef POINTER_TRICK
		memcpy(workingstate->bits, (buff+1), BLOCKS_IN_WORLD);
#else
        workingstate->bits = (unsigned char*)(buff+1);
#endif
        state* sPtr = workingstate;
		if ( d->brad_hash->simple_was_present(sPtr,true,true)) {
            if (Error.NoError())   {
		      driver_output(d->port, d->erlang_true, 8);
            } else {
              int i = 0;
              ei_encode_version(d->state_buffer, &i);
	          ei_encode_string(d->state_buffer, &i, Error.Msg());
              driver_output(d->port, d->state_buffer, i);
            }
	    } else {
            if (Error.NoError())   {
		      driver_output(d->port, d->erlang_false, 9);
            } else {
              int i = 0;
              ei_encode_version(d->state_buffer, &i);
	          ei_encode_string(d->state_buffer, &i, Error.Msg());
              driver_output(d->port, d->state_buffer, i);
            }
		}
    } else if (fn == 10) {
      int i = 0; 
#ifndef POINTER_TRICK
      memcpy(workingstate->bits, (buff+1), BLOCKS_IN_WORLD);
#else
      workingstate->bits = (unsigned char*)(buff+1);
#endif
      workingstate->Normalize();
      ei_encode_version(d->state_buffer, &i);
	  ei_encode_binary(d->state_buffer, &i, workingstate->bits, BLOCKS_IN_WORLD); 
      driver_output(d->port, d->state_buffer, i);
    } else if (fn == 2) {
      int count = Rules->AllNextStatesList((buff+1), d->state_buffer);
      if (Error.NoError())  {
        driver_output(d->port, d->state_buffer, count);
      } else {
        int i = 0;
        ei_encode_version(d->state_buffer, &i);
        ei_encode_tuple_header(d->state_buffer, &i, 3);
        ei_encode_atom(d->state_buffer, &i, "error");
        ei_encode_string(d->state_buffer, &i, Error.Msg());
        ei_encode_long(d->state_buffer, &i, (unsigned long)(Rules->whatRule()));
        Error.ResetErrorFlag();
        driver_output(d->port, d->state_buffer, i);
      }
/*
    } else if (fn == 21) {
      //state X,Y;
      int i = 0;
      int index = 0;
      int arity;
      //if (ei_decode_tuple_header(buff+1, &index, &arity)) {
      //  printf("error2 in Murphi Engine\n"); exit(1);
      //}
      printf("Murphi Engine says hi\n");fflush(0); 
      long in_state_count;
      if (ei_decode_long(buff+1, &index, &in_state_count)) {
        printf("error in Murphi Engine\n"); exit(1);
      }
      printf("Murphi Engine recieved %d states\n",in_state_count);
      ei_encode_version(d->state_buffer, &i);
      for (int j=0;j<in_state_count;j++) {
        ei_encode_list_header(d->state_buffer, &i, 1);
        i += Rules->AllNextStatesList((buff+1)+(BLOCKS_IN_WORLD*j), d->state_buffer);
      }
      ei_encode_empty_list(d->state_buffer, &i);
      driver_output(d->port, d->state_buffer, i);
*/
    } else if (fn == 1) {
/*
      if (StartStateManager::numstartstates > MAX_NEXT_STATES) {
        int i = 0;
        ei_encode_version(d->state_buffer, &i);
        ei_encode_tuple_header(d->state_buffer, &i, 2);
        ei_encode_atom(d->state_buffer, &i, "error");
        ei_encode_string(d->state_buffer, &i, "number of start states too big for murphi engine; try increasing MAX_NEXT_STATES in MurphiEngine/include/mu_epilog.inc");
        //ei_encode_long(d->state_buffer, &i, (unsigned long)(Rules->whatRule()));
        driver_output(d->port, d->state_buffer, i);
      } else {
*/
        int count = StartState->AllStartStatesList(d->state_buffer);
        if (Error.NoError())  {
          driver_output(d->port, d->state_buffer, count);
        } else {
          int i = 0;
          ei_encode_version(d->state_buffer, &i);
	      ei_encode_tuple_header(d->state_buffer, &i, 2);
	      ei_encode_atom(d->state_buffer, &i, "error");
	      ei_encode_string(d->state_buffer, &i, Error.Msg());
	      //ei_encode_long(d->state_buffer, &i, (unsigned long)(Rules->whatRule()));
          Error.ResetErrorFlag();
          driver_output(d->port, d->state_buffer, i);
        }
 //     }
    } else if (fn == 3) {
      int count = Properties->CheckInvariantsErl((buff+1), d->state_buffer);
      if (!Error.NoError())  {
        printf("error 1\n");fflush(0);
      }
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 4) {
      int count = Properties->StateToString((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 5) {
      int count = Properties->is_p_state((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 6) {
      int count = Properties->is_q_state((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 7) {
      int count = Properties->has_cangetto((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 8) {
      int count = Properties->PrintDiff((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
  // JESSE: we nuked the FastHash code for licensing reasons
  //  } else if (fn == 9) {
  //    int count = Properties->FastHash((buff+1), d->state_buffer);
  //    driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 11) {
      unsigned char rule = *(buff+1);
      int count = Rules->NextStatePreach((buff+2), d->state_buffer,rule);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 12) {
      unsigned int rule = *((unsigned int *)(buff+1));
      int count = Rules->RuleName(d->state_buffer, rule);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 13) {
      unsigned char ss_num = *((unsigned char *)(buff+1));
      int count = StartState->StartStateName(d->state_buffer, ss_num);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 15) {
      int count = Rules->whatRuleFired((buff+1), d->state_buffer);
      driver_output(d->port, d->state_buffer, count);      
    } else if (fn == 16) {
      unsigned long hash_MB = *((unsigned int*)(buff+1));
      //printf("murphi engine got hash_MB = %d \n",hash_MB);
      unsigned long hash_Bytes = 1024*1024*hash_MB;
      unsigned long hsize0 = hash_Bytes * 8 / state_set::bits_per_state();
      unsigned long hsize = NextPrime(hsize0);
      //fprintf(preachlog,"allocating a hash table of size %u MB, %lu states, %lu bytes\n", hash_MB,hsize,hash_Bytes);
      d->brad_hash = new state_set(hsize); 
      h3 = new hash_function(BLOCKS_IN_WORLD);
      driver_output(d->port, d->state_buffer, 0);      
    } else if (fn == 17) {
      int i=0;
      ei_encode_version(d->state_buffer, &i);
      ei_encode_double(d->state_buffer, &i,d->brad_hash->ProbAtLeastOneOmittedState());
      driver_output(d->port, d->state_buffer, i);
    } else if (fn == 18) {
       //args->sym_alg.set(argsym_alg::Exhaustive_Fast_Canonicalize);
       //args->sym_alg.set(argsym_alg::Heuristic_Fast_Canonicalize);
      args->perm_limit.set(0);
      int i = 0; 
//#ifndef POINTER_TRICK
      memcpy(workingstate->bits, (buff+1), BLOCKS_IN_WORLD);
//#else
      //workingstate->bits = (unsigned char*)(buff+1);
//#endif
      //workingstate->Exhaustive_Fast_Canonicalize();
      //workingstate->Heuristic_Fast_Canonicalize();
      workingstate->Normalize();
      ei_encode_version(d->state_buffer, &i);
	  ei_encode_binary(d->state_buffer, &i, workingstate->bits, BLOCKS_IN_WORLD); 
      driver_output(d->port, d->state_buffer, i);
    } else if (fn == 19) {
      state X,Y;
      memcpy(X.bits, buff+1, BLOCKS_IN_WORLD);
      memcpy(Y.bits, buff+1+BLOCKS_IN_WORLD, BLOCKS_IN_WORLD);
      if (StateEquivalent(&X,&Y))
        driver_output(d->port, d->erlang_true, 8);
      else
        driver_output(d->port, d->erlang_false, 9);
    } else if (fn == 20) {
      int i=0;
      ei_encode_version(d->state_buffer, &i);
      ei_encode_ulong(d->state_buffer, &i,(unsigned long)(d->brad_hash->NumCollisions()));
      driver_output(d->port, d->state_buffer, i);
    } else if (fn == 21) {
      int count = Rules->OneNextState((buff+1), d->state_buffer);
      if (Error.NoError())  {
        driver_output(d->port, d->state_buffer, count);
      } else {
        int i = 0;
        ei_encode_version(d->state_buffer, &i);
        ei_encode_tuple_header(d->state_buffer, &i, 3);
        ei_encode_atom(d->state_buffer, &i, "error");
        ei_encode_string(d->state_buffer, &i, Error.Msg());
        ei_encode_long(d->state_buffer, &i, (unsigned long)(Rules->whatRule()));
        Error.ResetErrorFlag();
        driver_output(d->port, d->state_buffer, i);
      }
    } else if (fn == 22) {
      unsigned int rule = *((unsigned int *)(buff+1));
      Rules->rule_mask[rule]=(char)1;
      driver_output(d->port, d->state_buffer, 0);      
    } else if (fn == 23) {
      int i = 0;
      ei_encode_version(d->state_buffer, &i);
      ei_encode_long(d->state_buffer, &i, (unsigned long)(RULES_IN_WORLD));
      driver_output(d->port, d->state_buffer, i);
    } else if (fn == 24) {
      unsigned long hash_MB = *((unsigned int*)(buff+1));
      unsigned long hash_Bytes = 1024*1024*hash_MB;
      unsigned long hsize0 = hash_Bytes * 8 / state_set::bits_per_state();
      unsigned long hsize = NextPrime(hsize0);
      d->cgt_hash = new state_set(hsize); 
      driver_output(d->port, d->state_buffer, 0);      
    } else if (fn == 25) {
        //int start_time = clock();
		memcpy(workingstate->bits, (buff+1), BLOCKS_IN_WORLD);
        state* sPtr = workingstate;
		if ( d->cgt_hash->full ) {
           int i = 0;
           ei_encode_version(d->state_buffer, &i);
	       ei_encode_atom(d->state_buffer, &i, "full");
           driver_output(d->port, d->state_buffer, i);
        } else {
		   if ( d->cgt_hash->is_present(sPtr)) {
		      driver_output(d->port, d->erlang_true, 8);
	       } else {
		      driver_output(d->port, d->erlang_false, 9);
		   }
        }
   } else if (fn == 26) {
		memcpy(workingstate->bits, (buff+1), BLOCKS_IN_WORLD);
        state* sPtr = workingstate;
		if ( d->cgt_hash->simple_was_present(sPtr,true,true)) {
            if (Error.NoError())   {
		      driver_output(d->port, d->erlang_true, 8);
            } else {
              int i = 0;
              ei_encode_version(d->state_buffer, &i);
	          ei_encode_string(d->state_buffer, &i, Error.Msg());
              driver_output(d->port, d->state_buffer, i);
            }
	    } else {
            if (Error.NoError())   {
		      driver_output(d->port, d->erlang_false, 9);
            } else {
              int i = 0;
              ei_encode_version(d->state_buffer, &i);
	          ei_encode_string(d->state_buffer, &i, Error.Msg());
              driver_output(d->port, d->state_buffer, i);
            }
		}
   } else {
      printf("Big trouble in Murphi Engine... exitting\n");
      exit(1);
   }
}

ErlDrvEntry example_driver_entry = {
    NULL,                       /* F_PTR init, N/A */
    example_drv_start,          /* L_PTR start, called when port is opened */
    example_drv_stop,           /* F_PTR stop, called when port is closed */
    example_drv_output,         /* F_PTR output, called when erlang has sent */
    NULL,                       /* F_PTR ready_input, called when input descriptor ready */
    NULL,                       /* F_PTR ready_output, called when output descriptor ready */
    PROTOCOL_NAME,              /* char *driver_name, the argument to open_port */
    NULL,                       /* F_PTR finish, called when unloaded */
    NULL,                       /* F_PTR control, port_command callback */
    NULL,                       /* F_PTR timeout, reserved */
    NULL                        /* F_PTR outputv, reserved */
};

DRIVER_INIT(PROTOCOL_NAME) /* must match name in driver_entry */
{
    return &example_driver_entry;
}

} /* end preach related crud */




/****************************************
  Old Log:
  1) 3 Dec 93 Norris Ip: 
  add #include "mu_sym.C"
  2) 8 March 94 Norris Ip:
  merge with the latest rel2.6
****************************************/

/********************
  $Log: mu_epilog.inc,v $
  Revision 1.2  1999/01/29 07:49:10  uli
  bugfixes

  Revision 1.4  1996/08/07 18:54:33  ip
  last bug fix on NextRule/SetNextEnabledRule has a bug; fixed this turn

  Revision 1.3  1996/08/07 01:00:18  ip
  Fixed bug on what_rule setting during guard evaluation; otherwise, bad diagnoistic message on undefine error on guard

  Revision 1.2  1996/08/07 00:15:26  ip
  fixed while code generation bug

  Revision 1.1  1996/08/07 00:14:46  ip
  Initial revision

********************/

