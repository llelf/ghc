\begin{code}
#include "HsVersions.h"

module TcEnv(
	TcEnv, 

	initEnv, getEnv_LocalIds, getEnv_TyCons, getEnv_Classes,
	
	tcTyVarScope, tcTyVarScopeGivenKinds, tcLookupTyVar, 

	tcExtendTyConEnv, tcLookupTyCon, tcLookupTyConByKey, 
	tcExtendClassEnv, tcLookupClass, tcLookupClassByKey,

	tcExtendGlobalValEnv, tcExtendLocalValEnv,
	tcLookupLocalValue, tcLookupLocalValueOK, tcLookupLocalValueByKey, 
	tcLookupGlobalValue, tcLookupGlobalValueByKey,

	newMonoIds, newLocalIds, newLocalId,
	tcGetGlobalTyVars
  ) where


import Ubiq
import TcMLoop  -- for paranoia checking

import Id	( Id(..), GenId, idType, mkUserLocal )
import TcHsSyn	( TcIdBndr(..), TcIdOcc(..) )
import TcKind	( TcKind, newKindVars, tcKindToKind, kindToTcKind )
import TcType	( TcType(..), TcMaybe, TcTyVar(..), TcTyVarSet(..), newTyVarTys, zonkTcTyVars )
import TyVar	( mkTyVar, getTyVarKind, unionTyVarSets, emptyTyVarSet )
import Type	( tyVarsOfTypes )
import TyCon	( TyCon, Arity(..), getTyConKind, getSynTyConArity )
import Class	( Class(..), GenClass, getClassSig )

import TcMonad

import Name	( Name(..), getNameShortName )
import PprStyle
import Pretty
import Unique	( Unique )
import UniqFM
import Util	( zipWithEqual, zipWith3Equal, zipLazy, panic )
\end{code}

Data type declarations
~~~~~~~~~~~~~~~~~~~~~

\begin{code}
data TcEnv s = TcEnv
		  (TyVarEnv s)
		  (TyConEnv s)
		  (ClassEnv s)
		  (ValueEnv Id)			-- Globals
		  (ValueEnv (TcIdBndr s))	-- Locals
		  (MutableVar s (TcTyVarSet s))	-- Free type variables of locals
						-- ...why mutable? see notes with tcGetGlobalTyVars

type TyVarEnv s  = UniqFM (TcKind s, TyVar)
type TyConEnv s  = UniqFM (TcKind s, Maybe Arity, TyCon)	-- Arity present for Synonyms only
type ClassEnv s  = UniqFM (TcKind s, Class)
type ValueEnv id = UniqFM id

initEnv :: MutableVar s (TcTyVarSet s) -> TcEnv s
initEnv mut = TcEnv emptyUFM emptyUFM emptyUFM emptyUFM emptyUFM mut 

getEnv_LocalIds (TcEnv _ _ _ _ ls _) = eltsUFM ls
getEnv_TyCons   (TcEnv _ ts _ _ _ _) = [tycon | (_, _, tycon) <- eltsUFM ts]
getEnv_Classes  (TcEnv _ _ cs _ _ _) = [clas  | (_, clas)     <- eltsUFM cs]
\end{code}

Making new TcTyVars, with knot tying!
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
tcTyVarScopeGivenKinds 
	:: [Name]			-- Names of some type variables
	-> [TcKind s]
	-> ([TyVar] -> TcM s a)		-- Thing to type check in their scope
	-> TcM s a			-- Result

tcTyVarScopeGivenKinds names kinds thing_inside
  = fixTc (\ ~(rec_tyvars, _) ->
		-- Ok to look at names, kinds, but not tyvars!

	tcGetEnv				`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
	let
	    tve' = addListToUFM tve (names `zip` (kinds `zipLazy` rec_tyvars))
	in
	tcSetEnv (TcEnv tve' tce ce gve lve gtvs) 
		 (thing_inside rec_tyvars)	`thenTc` \ result ->
 
		-- Get the tyvar's Kinds from their TcKinds
	mapNF_Tc tcKindToKind kinds		`thenNF_Tc` \ kinds' ->

		-- Construct the real TyVars
	let
	  tyvars	     = zipWithEqual mk_tyvar names kinds'
	  mk_tyvar name kind = mkTyVar (getNameShortName name) (getItsUnique name) kind
	in
	returnTc (tyvars, result)
    )					`thenTc` \ (_,result) ->
    returnTc result

tcTyVarScope names thing_inside
  = newKindVars (length names) 	`thenNF_Tc` \ kinds ->
    tcTyVarScopeGivenKinds names kinds thing_inside
\end{code}


The Kind, TyVar, Class and TyCon envs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Extending the environments.  Notice the uses of @zipLazy@, which makes sure
that the knot-tied TyVars, TyCons and Classes aren't looked at too early.

\begin{code}
tcExtendTyConEnv :: [(Name,Maybe Arity)] -> [TyCon] -> TcM s r -> TcM s r
tcExtendTyConEnv names_w_arities tycons scope
  = newKindVars (length names_w_arities)	`thenNF_Tc` \ kinds ->
    tcGetEnv					`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    let
	tce' = addListToUFM tce [ (name, (kind, arity, tycon)) 
				| ((name,arity), (kind,tycon)) <- names_w_arities `zip`
								  (kinds `zipLazy` tycons)
				]
    in
    tcSetEnv (TcEnv tve tce' ce gve lve gtvs) scope

tcExtendClassEnv :: [Name] -> [Class] -> TcM s r -> TcM s r
tcExtendClassEnv names classes scope
  = newKindVars (length names)	`thenNF_Tc` \ kinds ->
    tcGetEnv			`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    let
	ce' = addListToUFM ce (names `zip` (kinds `zipLazy` classes))
    in
    tcSetEnv (TcEnv tve tce ce' gve lve gtvs) scope
\end{code}


Looking up in the environments.

\begin{code}
tcLookupTyVar name
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM tve (panic "tcLookupTyVar") name)


tcLookupTyCon (WiredInTyCon tc)		-- wired in tycons
  = returnNF_Tc (kindToTcKind (getTyConKind tc), getSynTyConArity tc, tc)

tcLookupTyCon name
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM tce (panic "tcLookupTyCon") name)

tcLookupTyConByKey uniq
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    let 
       (kind, arity, tycon) =  lookupWithDefaultUFM_Directly tce (panic "tcLookupTyCon") uniq
    in
    returnNF_Tc tycon

tcLookupClass name
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM ce (panic "tcLookupClass") name)

tcLookupClassByKey uniq
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    let
	(kind, clas) = lookupWithDefaultUFM_Directly ce (panic "tcLookupClas") uniq
    in
    returnNF_Tc clas
\end{code}



Extending and consulting the value environment
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
tcExtendGlobalValEnv ids scope
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    let
	gve' = addListToUFM_Directly gve [(getItsUnique id, id) | id <- ids]
    in
    tcSetEnv (TcEnv tve tce ce gve' lve gtvs) scope

tcExtendLocalValEnv names ids scope
  = tcGetEnv		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    tcReadMutVar gtvs	`thenNF_Tc` \ global_tvs ->
    let
	lve' = addListToUFM lve (names `zip` ids)
	extra_global_tyvars = tyVarsOfTypes (map idType ids)
	new_global_tyvars   = global_tvs `unionTyVarSets` extra_global_tyvars
    in
    tcNewMutVar new_global_tyvars	`thenNF_Tc` \ gtvs' ->

    tcSetEnv (TcEnv tve tce ce gve lve' gtvs') scope
\end{code}

@tcGetGlobalTyVars@ returns a fully-zonked set of tyvars free in the environment.
To improve subsequent calls to the same function it writes the zonked set back into
the environment.

\begin{code}
tcGetGlobalTyVars :: NF_TcM s (TcTyVarSet s)
tcGetGlobalTyVars
  = tcGetEnv 				`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    tcReadMutVar gtvs			`thenNF_Tc` \ global_tvs ->
    zonkTcTyVars global_tvs		`thenNF_Tc` \ global_tvs' ->
    tcWriteMutVar gtvs global_tvs'	`thenNF_Tc_`
    returnNF_Tc global_tvs'
\end{code}

\begin{code}
tcLookupLocalValue :: Name -> NF_TcM s (Maybe (TcIdBndr s))
tcLookupLocalValue name
  = tcGetEnv 		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupUFM lve name)

tcLookupLocalValueByKey :: Unique -> NF_TcM s (Maybe (TcIdBndr s))
tcLookupLocalValueByKey uniq
  = tcGetEnv 		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupUFM_Directly lve uniq)

tcLookupLocalValueOK :: String -> Name -> NF_TcM s (TcIdBndr s)
tcLookupLocalValueOK err name
  = tcGetEnv 		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM lve (panic err) name)


tcLookupGlobalValue :: Name -> NF_TcM s Id

tcLookupGlobalValue (WiredInVal id)	-- wired in ids
  = returnNF_Tc id

tcLookupGlobalValue name
  = tcGetEnv 		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM gve def name)
  where
#ifdef DEBUG
    def = panic ("tcLookupGlobalValue:" ++ ppShow 1000 (ppr PprDebug name))
#else
    def = panic "tcLookupGlobalValue"
#endif


tcLookupGlobalValueByKey :: Unique -> NF_TcM s Id
tcLookupGlobalValueByKey uniq
  = tcGetEnv 		`thenNF_Tc` \ (TcEnv tve tce ce gve lve gtvs) ->
    returnNF_Tc (lookupWithDefaultUFM_Directly gve def uniq)
  where
#ifdef DEBUG
    def = panic ("tcLookupGlobalValueByKey:" ++ ppShow 1000 (ppr PprDebug uniq))
#else
    def = panic "tcLookupGlobalValueByKey"
#endif

\end{code}


Constructing new Ids
~~~~~~~~~~~~~~~~~~~~

\begin{code}
newMonoIds :: [Name] -> Kind -> ([TcIdBndr s] -> TcM s a) -> TcM s a
newMonoIds names kind m
  = newTyVarTys no_of_names kind	`thenNF_Tc` \ tys ->
    tcGetUniques no_of_names		`thenNF_Tc` \ uniqs ->
    let
	new_ids            = zipWith3Equal mk_id names uniqs tys
	mk_id name uniq ty = mkUserLocal (getOccurrenceName name) uniq ty
					 (getSrcLoc name)
    in
    tcExtendLocalValEnv names new_ids (m new_ids)
  where
    no_of_names = length names

newLocalId :: FAST_STRING -> TcType s -> NF_TcM s (TcIdOcc s)
newLocalId name ty
  = tcGetSrcLoc		`thenNF_Tc` \ loc ->
    tcGetUnique		`thenNF_Tc` \ uniq ->
    returnNF_Tc (TcId (mkUserLocal name uniq ty loc))

newLocalIds :: [FAST_STRING] -> [TcType s] -> NF_TcM s [TcIdOcc s]
newLocalIds names tys
  = tcGetSrcLoc			`thenNF_Tc` \ loc ->
    tcGetUniques (length names) `thenNF_Tc` \ uniqs ->
    let
	new_ids            = zipWith3Equal mk_id names uniqs tys
	mk_id name uniq ty = TcId (mkUserLocal name uniq ty loc)
    in
    returnNF_Tc new_ids
\end{code}


