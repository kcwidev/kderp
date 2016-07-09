;
; Copyright (c) 2013, California Institute of Technology. All rights
;	reserved.
;+
; NAME:
;	KCWI_SET_GEOM
;
; PURPOSE:
;	This procedure uses the input KCWI_CFG struct to set the basic
;	parameters in the KCWI_GEOM struct.
;
; CATEGORY:
;	Data reduction for the Keck Cosmic Web Imager (KCWI).
;
; CALLING SEQUENCE:
;	KCWI_SET_GEOM, Kgeom, iKcfg
;
; INPUTS:
;	Kgeom	- Input KCWI_GEOM struct.
;	iKcfg	- Input KCWI_CFG struct for a given observation.
;	Ppar	- Input KCWI_PPAR struct.
;
; KEYWORDS:
;	Atlas	- Arc atlas fits file (string, eg: 'fear.fits')
;	Atname	- Arc atlas name (string, eg: 'FeAr')
;
; OUTPUTS:
;	None
;
; SIDE EFFECTS:
;	Sets the following tags in the KCWI_GEOM struct according to the
;	configuration settings in KCWI_CFG.
;
; PROCEDURE:
;
; EXAMPLE:
;
; MODIFICATION HISTORY:
;	Written by:	Don Neill (neill@caltech.edu)
;	2013-AUG-13	Initial version
;	2016-JUN-12	Added KCWI gratings BH2,BH3, BM, BL
;	2016-JUL-01	Added atlas, atname keywords
;-
pro kcwi_set_geom,kgeom,ikcfg,ppar,atlas=atlas,atname=atname, help=help
	;
	; setup
	pre = 'KCWI_SET_GEOM'
	;
	; help request
	if keyword_set(help) then begin
		print,pre+': Info - Usage: '+pre+', Kgeom, Kcfg, Ppar'
		return
	endif
	;
	; verify Kgeom
	ksz = size(kgeom)
	if ksz[2] eq 8 then begin
		if kgeom.initialized ne 1 then begin
			print,pre+': Error - KCWI_GEOM struct not initialized.'
			return
		endif
	endif else begin
		print,pre+': Error - malformed KCWI_GEOM struct'
		return
	endelse
	;
	; verify Kcfg
	if kcwi_verify_cfg(ikcfg,/silent) ne 0 then begin
		print,pre+': Error - malformed KCWI_CFG struct'
		return
	endif
	;
	; verify Ppar
	psz = size(ppar)
	if psz[2] eq 8 then begin
		if ppar.initialized ne 1 then begin
			print,pre+': Error - KCWI_PPAR struct not initialized.'
			return
		endif
	endif else begin
		print,pre+': Error - malformed KCWI_PPAR struct'
		return
	endelse
	;
	; take singleton of KCWI_CFG
	kcfg = ikcfg[0]
	;
	; check image type
	if strtrim(strupcase(kcfg.imgtype),2) ne 'CBARS' then begin
		kcwi_print_info,ppar,pre,'cbars images are the geom reference files, this file is of type',kcfg.imgtype,/error
		return
	endif
	;
	; get output geom file name
	odir = ppar.reddir
	kgeom.geomfile = ppar.reddir + $
	    strmid(kcfg.obsfname,0,strpos(kcfg.obsfname,'_int')) + '_geom.save'
    	;
    	; set basic configuration parameters
    	kgeom.ifunum = kcfg.ifunum
	kgeom.ifunam = kcfg.ifunam
	kgeom.gratid = kcfg.gratid
	kgeom.gratnum = kcfg.gratnum
	kgeom.filter = kcfg.filter
	kgeom.filtnum = kcfg.filtnum
	kgeom.campos = kcfg.campos
	kgeom.camang = kcfg.camang
	kgeom.grenc = kcfg.grenc
	kgeom.grangle = kcfg.grangle
	kgeom.gratanom = kcfg.gratanom
	kgeom.xbinsize = kcfg.xbinsize
	kgeom.ybinsize = kcfg.ybinsize
	kgeom.nx = kcfg.naxis1
	kgeom.ny = kcfg.naxis2
	kgeom.x0out = 30 / kgeom.xbinsize
	kgeom.goody0 = 10
	kgeom.goody1 = kgeom.ny - 10
	kgeom.trimy0 = 0
	kgeom.trimy1 = kgeom.ny
	kgeom.ypad = 1400 / kgeom.ybinsize
	kgeom.nasmask = kcfg.nasmask
	if kcfg.nasmask eq 1 then begin
		kgeom.goody0 = kcfg.nsobjr0 + 18
		kgeom.goody1 = kcfg.nsobjr1 - 18
		kgeom.trimy0 = kcfg.nsobjr0 - 18
		kgeom.trimy1 = kcfg.nsobjr1 + 18
		kgeom.ypad = 0
	endif
	;
	; get noise model
	rdnoise = 0.
	;
	; sum over amp inputs
	switch kcfg.nvidinp of
		4: rdnoise = rdnoise + kcfg.biasrn4
		3: rdnoise = rdnoise + kcfg.biasrn3
		2: rdnoise = rdnoise + kcfg.biasrn2
		1: rdnoise = rdnoise + kcfg.biasrn1
	endswitch
	;
	; take average
	rdnoise /= float(kcfg.nvidinp)
	kgeom.rdnoise = rdnoise
	;
	; wavelength numbers default from header
	kgeom.cwave = kcfg.cwave
	kgeom.wave0out = kcfg.wave0	
	kgeom.wave1out = kcfg.wave1
	kgeom.dwout = kcfg.dwav
	;
	; reference spectrum: ppar value has top priority
	if strlen(strtrim(ppar.atlas,2)) gt 0 then begin
		kgeom.refspec = ppar.datdir+ppar.atlas
		kgeom.refname = ppar.atlasname
	endif else if keyword_set(atlas) then begin
		kgeom.refspec = ppar.datdir+atlas
		kgeom.refname = atname
	endif else begin
		kgeom.refspec = ppar.datdir+'fear.fits'
		kgeom.refname = 'FeAr'
	endelse
	;
	; default to no cc offsets
	kgeom.ccoff = fltarr(24)
	;
	; grating parameters BH1
	if strtrim(kcfg.gratid,2) eq 'BH1' then begin
		kgeom.resolution = 0.5
		kgeom.ccwn = 360./kgeom.ybinsize
		kgeom.rho = 3.751d
		kgeom.adjang = 180.d
		kgeom.lastdegree = 4
		kgeom.bclean = 1
		;
		; output disperison
		kgeom.dwout = 0.095 * float(kcfg.ybinsize)
	endif
	;
	; grating parameters BH2
	if strtrim(kcfg.gratid,2) eq 'BH2' then begin
		kgeom.resolution = 0.5
		kgeom.ccwn = 360./kgeom.ybinsize
		kgeom.rho = 3.255d
		kgeom.adjang = 180.d
		kgeom.lastdegree = 4
		kgeom.bclean = 0
		;
		; output disperison
		kgeom.dwout = 0.095 * float(kcfg.ybinsize)
	endif
	;
	; grating parameters BH3
	if strtrim(kcfg.gratid,2) eq 'BH3' then begin
		kgeom.resolution = 0.5
		kgeom.ccwn = 360./kgeom.ybinsize
		kgeom.rho = 2.80d
		kgeom.adjang = 180.d
		kgeom.lastdegree = 4
		kgeom.bclean = 0
		;
		; output disperison
		kgeom.dwout = 0.095 * float(kcfg.ybinsize)
	endif
	;
	; grating parameters BM
	if strtrim(kcfg.gratid,2) eq 'BM' then begin
		kgeom.resolution = 1.00
		kgeom.ccwn = 260./kgeom.ybinsize
		kgeom.rho = 1.900d
		kgeom.adjang = 0.d
		kgeom.lastdegree = 4
		kgeom.bclean = 0
		;
		; output disperison
		kgeom.dwout = 0.38 * float(kcfg.ybinsize)
	endif
	;
	; grating parameters BL
	if strtrim(kcfg.gratid,2) eq 'BL' then begin
		kgeom.resolution = 2.0
		kgeom.ccwn = 320./kgeom.ybinsize
		kgeom.rho = 0.870d
		kgeom.adjang = 0.d
		kgeom.lastdegree = 4
		kgeom.bclean = 1
		;
		; output disperison
		kgeom.dwout = 0.95 * float(kcfg.ybinsize)
	endif
	;
	; spatial scales
	kgeom.pxscl = 0.00004048d0	; deg/unbinned pixel
	kgeom.slscl = 0.00037718d0	; deg/slice, Large slicer
	if kcfg.ifunum eq 2 then begin
		kgeom.slscl = kgeom.slscl/2.d0
		kgeom.resolution = kgeom.resolution/2.00
	endif else if kcfg.ifunum eq 3 then begin
		kgeom.slscl = kgeom.slscl/4.d0
		kgeom.resolution = kgeom.resolution/4.00
	endif
	;
	; check central wavelength
	if kgeom.cwave le 0. then begin
		kcwi_print_info,ppar,pre,'No central wavelength found',/error
		return
	endif
	;
	; now check ppar values which override defaults
	if ppar.dw gt 0. then $
		kgeom.dwout = ppar.dw
	if ppar.wave0 gt 0. then $
		kgeom.wave0out = ppar.wave0
	if ppar.wave1 gt 0. then $
		kgeom.wave1out = ppar.wave1
	if ppar.cleancoeffs gt -1. then $
		kgeom.bclean = ppar.cleancoeffs
	;
	; print log of values
	kcwi_print_info,ppar,pre,'Data cube output Disp (A/px), Wave0 (A): ', $
		kgeom.dwout,kgeom.wave0out,format='(a,f8.3,f9.2)'
	;
	return
end