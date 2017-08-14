;
; Copyright (c) 2014, California Institute of Technology. All rights
;	reserved.
;+
; NAME:
;	KCWI_MAKE_STD
;
; PURPOSE:
;	This procedure creates a standard star inverse sensitivity
;	spectrum (in units of Flam/e-) from the input data cube.
;
; CATEGORY:
;	Data reduction for the Keck Cosmic Web Imager (KCWI).
;
; CALLING SEQUENCE:
;	KCWI_MAKE_STD, Kcfg,  Ppar, Invsen
;
; INPUTS:
;	Kcfg	- KCWI_CFG struct for the input data cube, preferrably
;			from a sky or dome-flat observation
;	Ppar	- KCWI_PPAR pipeline parameter struct
;
; OUTPUTS:
;	Invsen	- a vector giving the inverse sensitivity in Flam/e-
;
; SIDE EFFECTS:
;	Outputs a fits image of the standard star inverse sensitivity with 
;	same image number root as the input file, but with '_std'
;	appended. For example, if 'image1234.fits' is pointed to by the
;	input KCWI_CFG struct, then the output std image would have the
;	filename 'image1234_std.fits'.
;
; KEYWORDS:
;	None
;
; PROCEDURE:
;	Find the standard star in the slices, sky subtract and then add up
;	the flux.  Read in standard star flux and divide to get effective
;	inverse sensitivity (Flam/e-).
;
; EXAMPLE:
;
; TODO:
;	fit low-order polynomial to invsen function
;	mask known atmospheric lines/bands
;
; MODIFICATION HISTORY:
;	Written by:	Don Neill (neill@caltech.edu)
;	2014-APR-22	Initial Revision
;	2014-SEP-23	Added extinction correction
;-
pro kcwi_make_std,kcfg,ppar,invsen
	;
	; setup
	pre = 'KCWI_MAKE_STD'
	q=''
	;
	; check inputs
	if kcwi_verify_cfg(kcfg,/init) ne 0 then return
	if kcwi_verify_ppar(ppar,/init) ne 0 then return
	;
	; log
	kcwi_print_info,ppar,pre,systime(0)
	;
	; is this a standard star object observation?
	if strmatch(strtrim(kcfg.imgtype,2),'object') eq 0 then begin
		kcwi_print_info,ppar,pre,'not a std obs',/warning
	endif
	;
	; directories
	if kcwi_verify_dirs(ppar,rawdir,reddir,cdir,ddir) ne 0 then begin
		kcwi_print_info,ppar,pre,'Directory error, returning',/error
		return
	endif
	;
	; get output image (in reduced directory)
	ofil = kcwi_get_imname(ppar,kcfg.imgnum,'_invsens',/reduced)
	if file_test(ofil) then begin
		if ppar.clobber ne 1 then begin
			kcwi_print_info,ppar,pre, $
				'output file already exists',ofil,/error
			return
		endif else $
			kcwi_print_info,ppar,pre, $
				'output file will be overwritten',ofil,/warning
	endif
	;
	; read in image
	icub = kcwi_read_image(kcfg.imgnum,ppar,'_icubed',hdr,/calib, $
								status=stat)
	if stat ne 0 then begin
		kcwi_print_info,ppar,pre,'could not read input file',/error
		return
	endif
	;
	; check standard
	sname = strcompress(strlowcase(strtrim(kcfg.targname,2)),/remove)
	;
	; is standard file available?
	spath = !KCWI_DATA + '/stds/'+sname+'.fits'
	if not file_test(spath) then begin
		kcwi_print_info,ppar,pre, $
			'standard star data file not found for: '+sname,/error
		return
	endif
	kcwi_print_info,ppar,pre, $
		'generating effective inverse sensitivity curve from '+sname
	;
	; get size
	sz = size(icub,/dim)
	;
	; default pixel ranges
	z = findgen(sz[2])
	z0 = 175
	z1 = sz[2] - 175
	;
	; get exposure time
	expt = sxpar(hdr,'XPOSURE')
	if expt eq 0. then begin
		kcwi_print_info,ppar,pre, $
			'no exposure time found, setting to 1s',/warn
		expt = 1.
	endif else $
		kcwi_print_info,ppar,pre,'Using exposure time of',expt,/info
	;
	; get wavelength scale
	w0 = sxpar(hdr,'CRVAL3')
	dw = sxpar(hdr,'CD3_3')
	crpixw = sxpar(hdr,'CRPIX3')
	;
	; get all good wavelength range
	wgoo0 = sxpar(hdr,'WAVGOOD0') > 3650.0
	wgoo1 = sxpar(hdr,'WAVGOOD1')
	;
	; get all inclusive wavelength range
	wall0 = sxpar(hdr,'WAVALL0')
	wall1 = sxpar(hdr,'WAVALL1')
	;
	; get telescope and atm. correction
	tel = strtrim(sxpar(hdr,'telescop',count=ntel),2)
	if ntel le 0 then tel = 'Keck II'
	area = -1.0
	if strpos(tel,'Keck') ge 0 then begin
		area = 760000.d0	; Keck effective area in cm^2
	endif else if strpos(tel,'5m') ge 0 then begin
		area = 194165.d0	; Hale 5m area in cm^2
	endif
	tlab = tel
	;
	; compute good y pixel ranges
	if w0 gt 0. and dw gt 0. and wgoo0 gt 0. and wgoo1 gt 0. then begin
		z0 = fix( (wgoo0 - w0) / dw ) + 10
		z1 = fix( (wgoo1 - w0) / dw ) - 10
	endif
	gz = where(z ge z0 and z le z1)
	;
	; wavelength scale
	w = w0 + z*dw
	;
	; good spatial range
	gy0 = 1
	gy1 = sz[1] - 2
	;
	; log results
	kcwi_print_info,ppar,pre,'Invsen. Pars: Y0, Y1, Z0, Z1, Wav0, Wav1', $
		gy0,gy1,z0,z1,w[z0],w[z1],format='(a,4i6,2f9.3)'
	;
	; display status
	doplots = (ppar.display ge 2)
	;
	; find standard in slices
	tot = total(icub[*,gy0:gy1,z0:z1],3)
	yy = findgen(gy1-gy0)+gy0
	mxsl = -1
	mxsg = 0.
	for i=0,sz[0]-1 do begin
		mo = moment(tot[i,*])
		if sqrt(mo[1]) gt mxsg then begin
			mxsg = sqrt(mo[1])
			mxsl = i
		endif
	endfor
	;
	; relevant slices
	sl0 = (mxsl-3)>0
	sl1 = (mxsl+3)<(sz[0]-1)
	;
	; get y position of std
	cy = (pkfind(tot[mxsl,*],npeaks,thresh=0.99))[0] + gy0
	;
	; log results
	kcwi_print_info,ppar,pre,'Std slices; max, sl0, sl1, spatial cntrd', $
		mxsl,sl0,sl1,cy,format='(a,3i4,f9.2)'
	;
	; do sky subtraction
	scub = icub
	deepcolor
	!p.background=colordex('white')
	!p.color=colordex('black')
	skywin = ppar.psfwid/kcfg.xbinsize
	for i=sl0,sl1 do begin
		skyspec = fltarr(sz[2])
		for j = 0,sz[2]-1 do begin
			skyv = reform(icub[i,gy0:gy1,j])
			gsky = where(yy le (cy-skywin) or yy ge (cy+skywin))
			sky = median(skyv[gsky])
			skyspec[j] = sky
			scub[i,*,j] = icub[i,*,j] - sky
		endfor
		if doplots then begin
			yrng = get_plotlims(skyspec[gz])
			plot,w,skyspec,title='Slice '+strn(i)+ $
				' SKY, Img #: '+strn(kcfg.imgnum), $
				xtitle='Wave (A)', xran=[wall0,wall1], /xs, $
				ytitle='Sky e-', yran=yrng, /ys
			oplot,[wgoo0,wgoo0],!y.crange,color=colordex('green'), $
				thick=3
			oplot,[wgoo1,wgoo1],!y.crange,color=colordex('green'), $
				thick=3
			read,'Next? (Q-quit plotting, <cr> - next): ',q
			if strupcase(strmid(strtrim(q,2),0,1)) eq 'Q' then $
				doplots = 0
		endif
	endfor
	;
	; recover plot status
	doplots = (ppar.display ge 2)
	;
	; apply extinction correction
	ucub = scub	; uncorrected cube
	kcwi_correct_extin, scub, hdr, ppar
	;
	; get slice spectra
	slspec = total(scub[*,gy0:gy1,*],2)
	ulspec = total(ucub[*,gy0:gy1,*],2)
	;
	; summed observed standard spectra
	obsspec = total(slspec[sl0:sl1,*],1)
	ubsspec = total(ulspec[sl0:sl1,*],1)
	;
	; convert to e-/second
	obsspec = obsspec / expt
	ubsspec = ubsspec / expt
	;
	; read in standard
	sdat = mrdfits(spath,1,shdr)
	swl = sdat.wavelength
	sflx = sdat.flux	; Units of Flam
	sfw = sdat.fwhm
	;
	; get region of interest
	sroi = where(swl ge wall0 and swl le wall1, nsroi)
	if nsroi le 0 then begin
		kcwi_print_info,ppar,pre, $
			'no standard wavelengths in common',/error
		return
	;
	; very sparsely sampled w.r.t. object
	endif else if nsroi eq 1 then begin
		;
		; up against an edge, no good
		if sroi[0] le 0 or sroi[0] ge n_elements(swl)-1L then begin
			kcwi_print_info,ppar,pre, $
				'standard wavelengths not a good match',/error
			return
		;
		; manually expand sroi to allow linterp to work
		endif else begin
			sroi = [ sroi[0]-1, sroi[0], sroi[0]+1 ]
		endelse
	endif
	swl = swl[sroi]
	sflx = sflx[sroi]
	sfw = sfw[sroi]
	fwhm = max(sfw)
	kcwi_print_info,ppar,pre,'reference spectrum FWHM used',fwhm, $
					'Angstroms', format='(a,f5.1,1x,a)'
	;
	; smooth to this resolution
	if kcfg.nasmask then begin
		obsspec = gaussfold(w,obsspec,fwhm)
		ubsspec = gaussfold(w,ubsspec,fwhm)
	endif else begin
		obsspec = gaussfold(w,obsspec,fwhm,lammin=wgoo0,lammax=wgoo1)
		ubsspec = gaussfold(w,ubsspec,fwhm,lammin=wgoo0,lammax=wgoo1)
	endelse
	;
	; resample standard onto our wavelength grid
	linterp,swl,sflx,w,rsflx
	;
	; get effective inverse sensitivity
	invsen = rsflx / obsspec
	;
	; convert to photons
	rspho = 5.03411250d+07 * rsflx * w * dw
	;
	; get effective area
	earea = ubsspec / rspho
	;
	; fit smoothed inverse sensitivity
	t=where(w ge wgoo0 and w le wgoo1, nt)
	if nt gt 0 then begin
		sf = smooth(invsen[t],250)
		wf = w - min(w)
		;
		; polynomial fit
		res = poly_fit(wf[t],sf,5,/double)
		finvsen = poly(wf,res)
	endif else begin
		kcwi_print_info,ppar,pre,'no good wavelengths to fit',/error
	endelse
	;
	; plot effective inverse sensitivity
	if doplots then begin
		yrng = get_plotlims(invsen[gz])
		plot,w,invsen,title=sname+' Img #: '+strn(kcfg.imgnum), $
			xtitle='Wave (A)',xran=[wall0,wall1],/xs, $
			ytitle='Effective Inv. Sens. (erg/cm^2/A/e-)', $
			yran=yrng,/ys,xmargin=[11,3]
		oplot,w,finvsen,color=colordex('red')
		oplot,[wgoo0,wgoo0],!y.crange,color=colordex('green'),thick=3
		oplot,[wgoo1,wgoo1],!y.crange,color=colordex('green'),thick=3
		read,'Next: ',q
		;
		; plot effective area (cm^2)
		goo = where(w gt wgoo0 and w lt wgoo1, ngoo)
		if ngoo gt 5 then begin
			maxea = max(earea[goo])
			mo = moment(earea[goo])
			yrng = get_plotlims(earea[goo])
			sea = smooth(earea[goo],250)
			sex = w[goo] - min(w[goo])
			res = poly_fit(sex,sea,5,yfit=fea,/double)
		endif else begin
			maxea = max(earea)
			mo = moment(earea)
			yrng = get_plotlims(earea)
		endelse
		if yrng[0] lt 0. then yrng[0] = 0.0
		if area gt 0 then begin
			plot,w,earea, $
				title=sname+' Img #: '+strn(kcfg.imgnum)+' '+ $
				strtrim(kcfg.bgratnam,2)+' '+tlab, $
				xtitle='Wave (A)',xran=[wall0,wall1],/xs, $
				ytitle='Effective Area (cm^2/A)',ys=9, $
				yran=yrng,xmargin=[11,8]
			oplot,[wgoo0,wgoo0],!y.crange,color=colordex('green'), $
				thick=3
			oplot,[wgoo1,wgoo1],!y.crange,color=colordex('green'), $
				thick=3
			oplot,!x.crange,[maxea,maxea],linesty=2
			oplot,!x.crange,[mo[0],mo[0]],linesty=3
			axis,yaxis=1,yrange=100.*(!y.crange/area),ys=1, $
				ytitle='Efficiency (%)'
		endif else begin
			plot,w,earea,title=sname+' Img #: '+strn(kcfg.imgnum), $
				xtitle='Wave (A)',xran=[wall0,wall1],/xs, $
				ytitle='Effective Area (cm^2/A)',yran=yrng,/ys
			oplot,[wgoo0,wgoo0],!y.crange,color=colordex('green'), $
				thick=3
			oplot,[wgoo1,wgoo1],!y.crange,color=colordex('green'), $
				thick=3
			oplot,!x.crange,[maxea,maxea],linesty=2
			oplot,!x.crange,[mo[0],mo[0]],linesty=3
		endelse
		;
		; overplot fit
		if ngoo gt 5 then $
			oplot,w[goo],fea,thick=5,color=colordex('blue')
		read,'Next: ',q
	endif
	;
	; write out effective inverse sensitivity
	;
	; update invsens header
	sxaddpar,hdr,'HISTORY','  '+pre+' '+systime(0)
	sxaddpar,hdr,'INVSENS','T',' effective inv. sens. spectrum?'
	sxaddpar,hdr,'INVSW0',w[z0],' low wavelength for eff inv. sens.', $
		format='F9.2'
	sxaddpar,hdr,'INVSW1',w[z1],' high wavelength for eff inv. sens.', $
		format='F9.2'
	sxaddpar,hdr,'INVSZ0',z0,' low wave pixel for eff inv. sens.'
	sxaddpar,hdr,'INVSZ1',z1,' high wave pixel for eff inv. sens.'
	sxaddpar,hdr,'INVSY0',gy0,' low spatial pixel for eff inv. sens.'
	sxaddpar,hdr,'INVSY1',gy1,' high spatial pixel for eff inv. sens.'
	sxaddpar,hdr,'INVSLMX',mxsl,' brightest std star slice'
	sxaddpar,hdr,'INVSL0',sl0,' lowest std star slice summed'
	sxaddpar,hdr,'INVSL1',sl1,' highest std star slice summed'
	sxaddpar,hdr,'INVSLY',cy,' spatial pixel position of std within slice'
	sxaddpar,hdr,'BUNIT','erg/cm^2/A/e-',' brightness units'
	sxaddpar,hdr,'EXPTIME',1.,' effective exposure time (seconds)'
	sxaddpar,hdr,'XPOSURE',1.,' effective exposure time (seconds)'
	;
	; remove old WCS
	sxdelpar,hdr,'RADESYS'
	sxdelpar,hdr,'EQUINOX'
	sxdelpar,hdr,'LONPOLE'
	sxdelpar,hdr,'LATPOLE'
	sxdelpar,hdr,'NAXIS2'
	sxdelpar,hdr,'NAXIS3'
	sxdelpar,hdr,'CTYPE1'
	sxdelpar,hdr,'CTYPE2'
	sxdelpar,hdr,'CTYPE3'
	sxdelpar,hdr,'CUNIT1'
	sxdelpar,hdr,'CUNIT2'
	sxdelpar,hdr,'CUNIT3'
	sxdelpar,hdr,'CNAME1'
	sxdelpar,hdr,'CNAME2'
	sxdelpar,hdr,'CNAME3'
	sxdelpar,hdr,'CRVAL1'
	sxdelpar,hdr,'CRVAL2'
	sxdelpar,hdr,'CRVAL3'
	sxdelpar,hdr,'CRPIX1'
	sxdelpar,hdr,'CRPIX2'
	sxdelpar,hdr,'CRPIX3'
	sxdelpar,hdr,'CD1_1'
	sxdelpar,hdr,'CD1_2'
	sxdelpar,hdr,'CD2_1'
	sxdelpar,hdr,'CD2_2'
	sxdelpar,hdr,'CD3_3'
	;
	; set wavelength axis WCS values
	sxaddpar,hdr,'WCSDIM',1
	sxaddpar,hdr,'CTYPE1','AWAV',' Air Wavelengths'
	sxaddpar,hdr,'CUNIT1','Angstrom',' Wavelength units'
	sxaddpar,hdr,'CNAME1','KCWI INVSENS Wavelength',' Wavelength name'
	sxaddpar,hdr,'CRVAL1',w0,' Wavelength zeropoint'
	sxaddpar,hdr,'CRPIX1',crpixw,' Wavelength reference pixel'
	sxaddpar,hdr,'CDELT1',dw,' Wavelength Angstroms per pixel'
	;
	; write out inverse sensitivity file
	ofil = kcwi_get_imname(ppar,kcfg.imgnum,'_invsens',/nodir)
	kcwi_write_image,invsen,hdr,ofil,ppar
	;kcwi_write_image,finvsen,hdr,ofil,ppar
	;
	; update effective area header
	sxaddpar,hdr,'INVSENS','F',' effective inv. sens. spectrum?'
	sxaddpar,hdr,'EFFAREA','T',' effective area spectrum?'
	sxaddpar,hdr,'BUNIT','cm^2/A',' brightness units'
	sxaddpar,hdr,'CNAME1','KCWI EA Wavelength',' Wavelength name'
	;
	; write out effective area file
	ofil = kcwi_get_imname(ppar,kcfg.imgnum,'_ea',/nodir)
	kcwi_write_image,earea,hdr,ofil,ppar
	;
	return
end
