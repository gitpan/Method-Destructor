#define PERL_NO_GET_CONTEXT
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include "ppport.h"
#define NEED_mro_get_linear_isa
#include "mro_compat.h"

#ifndef GvSVn
#define GvSVn(gv) GvSV(gv)
#endif

#define META     "::Method::Destructor::"
#define DEMOLISH "DEMOLISH"

SV* meta_key;
U32 meta_hash;

enum md_flags{
	MDf_NONE       = 0x00,
	MDf_SKIP_DIRTY = 0x01
};

#define deref_gv(sv) md_deref_gv(aTHX_ sv)
static GV*
md_deref_gv(pTHX_ SV* const gvref){
	if(!(SvROK(gvref) && isGV(SvRV(gvref)))){
		Perl_croak(aTHX_ "Not a GLOB reference");
	}
	return (GV*)SvRV(gvref);
}

static void
md_call_demolishall(pTHX_ SV* const self, AV* const demolishall){
	SV**       svp = AvARRAY(demolishall);
	SV** const end = svp + AvFILLp(demolishall) + 1;

	while(svp != end){
		GV* const demolishgv = deref_gv(*svp);
		SV* const sv         = GvSV(demolishgv);
		IV  const flags      = (sv && SvIOK(sv)) ? SvIVX(sv) : MDf_NONE;

		if(!( (flags & MDf_SKIP_DIRTY) && PL_dirty )){
			dSP;

			PUSHMARK(SP);
			XPUSHs(self);
			PUTBACK;

			/*
			   NOTE: changes PL_stack_sp directly, instead of using G_DISCARD.
			*/
			PL_stack_sp -= call_sv((SV*)GvCV(demolishgv), G_VOID);
		}

		svp++;
	}
}

XS(XS_Method__Destructor_DESTROY);

MODULE = Method::Destructor	PACKAGE = Method::Destructor

PROTOTYPES: DISABLE

BOOT:
	meta_key = newSVpvs(META);
	PERL_HASH(meta_hash, META, sizeof(META)-1);

void
import(SV* klass, ...)
PREINIT:
	int i;
CODE:
	for(i = 1; i < items; i++){
		SV* const option = ST(i);
		if(strEQ(SvPV_nolen_const(option), "-optional")){
			GV* const gv = (GV*)*hv_fetchs(PL_curstash, DEMOLISH, TRUE);
			SV* flags;

			if(!isGV(gv)){
				gv_init(gv, PL_curstash, DEMOLISH, sizeof(DEMOLISH)-1, GV_ADDMULTI);
			}
			flags = GvSVn(gv);

			/* $flags |= MDf_SKIP_DIRTY */
			sv_setiv(flags, (SvIOK(flags) ? SvIVX(flags) : MDf_NONE) | MDf_SKIP_DIRTY);
		}
		else{
			Perl_croak(aTHX_ "Invalid option '%"SVf"' for %"SVf, option, klass);
		}
	}
	newXS("DESTROY", XS_Method__Destructor_DESTROY, __FILE__);

void
DESTROY(SV* self)
PREINIT:
	HV* stash;
	HE* he;
	GV* metagv;
	AV* demolishall;
	SV* gensv;
CODE:
	if(!( SvROK(self) && (stash = SvSTASH(SvRV(self))) )){
		Perl_croak(aTHX_ "Invalid call of DESTROY");
	}

	he     = hv_fetch_ent(stash, meta_key, TRUE, meta_hash);
	metagv = (GV*)HeVAL(he);

	if(!isGV(metagv)){
		gv_init(metagv, stash, META, sizeof(META)-1, GV_ADDMULTI);
		demolishall = GvAVn(metagv);
		gensv       = GvSVn(metagv);
		sv_setuv(gensv, 0U);
	}
	else{
		demolishall = GvAV(metagv);
		gensv       = GvSV(metagv);
	}

	if(SvUV(gensv) != mro_get_gen(stash)){
		AV*  const isa = mro_get_linear_isa(stash);
		SV**       svp = AvARRAY(isa);
		SV** const end = svp + AvFILLp(isa) + 1;

		if(AvFILLp(demolishall) > -1){
			av_clear(demolishall);
		}

		while(svp != end){
			HV*  const st  = gv_stashsv(*svp, TRUE);
			GV** const gvp = (GV**)hv_fetchs(st, DEMOLISH, FALSE);

			if(gvp && isGV(*gvp) && GvCVu(*gvp)){
				av_push(demolishall, newRV_inc((SV*)*gvp));
			}

			svp++;
		}
		sv_setuv(gensv, mro_get_gen(stash));
	}

	if(AvFILLp(demolishall) > -1){
		md_call_demolishall(aTHX_ self, demolishall);
	}
