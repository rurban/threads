
#include "threads.h"






/*
	Starts executing the thread. Needs to clean up memory a tad better.
*/

#ifdef WIN32
THREAD_RET_TYPE thread_run(LPVOID arg) {
	ithread* thread = (ithread*) arg;
#else
void thread_run(ithread* thread) {
#endif
	SV* thread_tid_ptr;
	SV* thread_ptr;

	PERL_SET_CONTEXT(shared_sv_space);
	MUTEX_LOCK(&thr_list_mutex);
	thread_tid_ptr = Perl_newSViv(shared_sv_space, (IV) thread->thr);
	thread_ptr = Perl_newSViv(shared_sv_space, (IV) thread);	
	Perl_hv_store_ent(shared_sv_space,threads, thread_tid_ptr, thread_ptr,0);
   	SvREFCNT_dec(thread_tid_ptr);
	MUTEX_UNLOCK(&thr_list_mutex);
	PERL_SET_CONTEXT(thread->interp);
	PL_perl_destruct_level = 2;

	{
		dTHXa(thread->interp);
		AV* params;
		I32 len;
		int i;
		dSP;
		params = (AV*) SvRV(thread->params);
		len = av_len(params);
		ENTER;
		SAVETMPS;
		PUSHMARK(SP);
		if(len > -1) {
			for(i = 0; i < len + 1; i++) {
				XPUSHs(av_shift(params));
			}	
		}
		PUTBACK;
	 	call_sv(thread->init_function, G_DISCARD);
		FREETMPS;
		LEAVE;


	}



	MUTEX_LOCK(&thread->mutex);
 	perl_destruct(thread->interp);	
	perl_free(thread->interp);
	if(thread->detached == 1) {
		MUTEX_UNLOCK(&thread->mutex);
		thread_destruct(thread);
	} else {
	  	MUTEX_UNLOCK(&thread->mutex);
   	}
#ifdef WIN32
	return (DWORD)0;
#endif

}



/*
	iThread->create();
*/

SV* thread_create(char* class, SV* init_function, SV* params) {
	ithread* thread = malloc(sizeof(ithread));
  	SV*      obj_ref;
  	SV*      obj;
	SV*		temp_store;
   I32		result;
	PerlInterpreter *current_perl;

	MUTEX_LOCK(&create_mutex);  
	obj_ref = newSViv(0);
	obj = newSVrv(obj_ref, class);
   sv_setiv(obj, (IV)thread);
   SvREADONLY_on(obj);


   current_perl = PERL_GET_CONTEXT;	

	/*
		here we put the values of params and function to call onto namespace, this is so perl will properly 		clone them when we call perl_clone.
	*/
	


	temp_store = Perl_get_sv(current_perl, "threads::paramtempstore", TRUE | GV_ADDMULTI);
	Perl_sv_setsv(current_perl, temp_store,params);
	params = NULL;
	temp_store = NULL;

	temp_store = Perl_get_sv(current_perl, "threads::calltempstore", TRUE | GV_ADDMULTI);
	Perl_sv_setsv(current_perl,temp_store, init_function);
	init_function = NULL;
	temp_store = NULL;
	

#ifdef WIN32
	thread->interp = perl_clone(current_perl,4);
#else
	thread->interp = perl_clone(current_perl,0);
#endif

	thread->init_function = newSVsv(Perl_get_sv(thread->interp, "threads::calltempstore",FALSE));
	thread->params = newSVsv(Perl_get_sv(thread->interp, "threads::paramtempstore",FALSE));





	/*
		And here we make sure we clean up the data we put in the namespace of iThread, both in the new and the calling inteprreter
	*/

	

	temp_store = Perl_get_sv(thread->interp,"threads::paramtempstore",FALSE);
	Perl_sv_setsv(thread->interp,temp_store, &PL_sv_undef);

	temp_store = Perl_get_sv(thread->interp,"threads::calltempstore",FALSE);
	Perl_sv_setsv(thread->interp,temp_store, &PL_sv_undef);

	PERL_SET_CONTEXT(current_perl);

	temp_store = Perl_get_sv(current_perl,"threads::paramtempstore",FALSE);
	Perl_sv_setsv(current_perl, temp_store, &PL_sv_undef);

	temp_store = Perl_get_sv(current_perl,"threads::calltempstore",FALSE);
	Perl_sv_setsv(current_perl, temp_store, &PL_sv_undef);

	/* lets init the thread */


//	thread->mutex = (perl_mutex) malloc(sizeof(perl_mutex));


	MUTEX_INIT(&thread->mutex);
	thread->tid = tid_counter++;
	thread->detached = 0;
	thread->count = 1;

#ifdef WIN32

	thread->handle = CreateThread(NULL, 0, thread_run,
			(LPVOID)thread, 0, &thread->thr);

#else
	pthread_create( &thread->thr, NULL, (void *) thread_run, thread);
#endif
	MUTEX_UNLOCK(&create_mutex);	



  return obj_ref;
}

/*
	returns the id of the thread
*/
I32 thread_tid (SV* obj) {
   ithread* thread = (ithread*)SvIV(SvRV(obj));
	return thread->tid;
}

SV* thread_self (char* class) {
   SV*      obj_ref;
   SV*      obj;
	SV*		thread_tid_ptr;
	SV*		thread_ptr;
	HE*		thread_entry;
	PerlInterpreter*	old_context;

	old_context = Perl_get_context();
	PERL_SET_CONTEXT(shared_sv_space);
#ifdef WIN32
	thread_tid_ptr = Perl_newSViv(shared_sv_space, (IV) GetCurrentThreadId());
#else
	thread_tid_ptr = Perl_newSViv(shared_sv_space, (IV) pthread_self());
#endif
	MUTEX_LOCK(&thr_list_mutex);
	thread_entry = Perl_hv_fetch_ent(shared_sv_space,threads, thread_tid_ptr, 0,0);
	thread_ptr = HeVAL(thread_entry);
	MUTEX_UNLOCK(&thr_list_mutex);
	SvREFCNT_dec(thread_tid_ptr);	
	PERL_SET_CONTEXT(old_context);
	
	

	obj_ref = newSViv(0);
	obj = newSVrv(obj_ref, class);
   	sv_setsv(obj, thread_ptr);
   	SvREADONLY_on(obj);
	return obj_ref;
}

/*
	joins the thread
	this code needs to take the returnvalue from the call_sv and send it back
*/

void thread_join(SV* obj) {
	ithread* thread = (ithread*)SvIV(SvRV(obj));
#ifdef WIN32
	DWORD waitcode;
	waitcode = WaitForSingleObject(thread->handle, INFINITE);
#else
	void *retval;
	pthread_join(thread->thr,&retval);
#endif
}


/*
	detaches a thread
	needs to better clean up memory
*/

void thread_detach(SV* obj) {
	ithread* thread = (ithread*)SvIV(SvRV(obj));
	MUTEX_LOCK(&thread->mutex);
	thread->detached = 1;
#if !defined(WIN32)
	pthread_detach(thread->thr);
#endif
	MUTEX_UNLOCK(&thread->mutex);
}



void thread_DESTROY (SV* obj) {
	ithread* thread = (ithread*)SvIV(SvRV(obj));
	
	MUTEX_LOCK(&thread->mutex);
	thread->count--;
	MUTEX_UNLOCK(&thread->mutex);
	thread_destruct(thread);

}

void thread_destruct (ithread* thread) {
	return;
	MUTEX_LOCK(&thread->mutex);
	if(thread->count != 0) {
		MUTEX_UNLOCK(&thread->mutex);
		return;	
	}
	MUTEX_UNLOCK(&thread->mutex);
	/* it is safe noone is holding a ref to this */
	/*printf("proper destruction!\n");*/
}


MODULE = threads		PACKAGE = threads		
BOOT:
	shared_sv_space = PERL_GET_CONTEXT;
	PL_perl_destruct_level = 2;
	threads = Perl_newHV(shared_sv_space);
	{
	    SV* temp = get_sv("threads::sharedsvspace", TRUE | GV_ADDMULTI);
	    SV* temp2 = newSViv((IV)shared_sv_space );
	    sv_setsv( temp , temp2 );
	}
	MUTEX_INIT(&create_mutex);
	MUTEX_INIT(&thr_list_mutex);



PROTOTYPES: DISABLE

SV *
create (class, function_to_call, ...)
        char *  class
        SV *    function_to_call
		CODE:
			AV* params = newAV();
			if(items > 2) {
				int i;
				for(i = 2; i < items ; i++) {
					av_push(params, ST(i));
				}
			}
			RETVAL = thread_create(class, function_to_call, newRV_noinc((SV*) params));
			OUTPUT:
			RETVAL

SV *
self (class)
		char* class
	CODE:
		RETVAL = thread_self(class);
	OUTPUT:
		RETVAL

int
tid (obj)	
		SV *	obj;
	CODE:
		RETVAL = thread_tid(obj);
	OUTPUT:
	RETVAL

void
join (obj)
        SV *    obj
        PREINIT:
        I32* temp;
        PPCODE:
        temp = PL_markstack_ptr++;
        thread_join(obj);
        if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
          PL_markstack_ptr = temp;
          XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
        return; /* assume stack size is correct */

void
detach (obj)
        SV *    obj
        PREINIT:
        I32* temp;
        PPCODE:
        temp = PL_markstack_ptr++;
        thread_detach(obj);
        if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
          PL_markstack_ptr = temp;
          XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
        return; /* assume stack size is correct */





void
DESTROY (obj)
        SV *    obj
        PREINIT:
        I32* temp;
        PPCODE:
        temp = PL_markstack_ptr++;
        thread_DESTROY(obj);
        if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
          PL_markstack_ptr = temp;
          XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
        return; /* assume stack size is correct */



