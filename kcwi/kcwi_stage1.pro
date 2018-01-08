;
; Copyright (c) 2013, California Institute of Technology. All rights
;	reserved.
;+
; NAME:
;	KCWI_STAGE1
;
; PURPOSE:
;	This procedure takes the data through basic CCD reduction which
;	includes: bias and overscan removal and trimming, gain correction,
;	cosmic ray removal, mask generation and variance image generation.
;
; CATEGORY:
;	Data reduction for the Keck Cosmic Web Imager (KCWI).
;
; CALLING SEQUENCE:
;	KCWI_STAGE1, Procfname, Pparfname
;
; OPTIONAL INPUTS:
;	Procfname - input proc filename generated by KCWI_PREP
;			defaults to './redux/kcwi.proc'
;	Pparfname - input ppar filename generated by KCWI_PREP
;			defaults to './redux/kcwi.ppar'
;
; KEYWORDS:
;	VERBOSE	- set to verbosity level to override value in ppar file
;	DISPLAY - set to display level to override value in ppar file
;
; OUTPUTS:
;	None
;
; SIDE EFFECTS:
;	Outputs processed files in output directory specified by the
;	KCWI_PPAR struct read in from Pparfname.
;
; PROCEDURE:
;	Reads Pparfname to derive input/output directories and reads the
;	corresponding '*.proc' file in output directory to derive the list
;	of input files and their associated master bias files.  Each input
;	file is read in and the required master bias is generated and 
;	subtracted.  The overscan region for each calibration and object 
;	image is then analyzed and a row-by-row subtraction is performed 
;	to remove 1/f noise in the readout.  The images are trimmed and 
;	assembled into physical CCD-sized images.  Next, a gain correction 
;	for each amplifier is applied to convert each image into electrons.
;	The object images are then analyzed for cosmic rays and a mask image 
;	is generated indicating where the cosmic rays were removed.  Variance 
;	images for each object image are generated from the cleaned images 
;	which accounts for Poisson and CCD read noise.
;
; EXAMPLE:
;	Perform stage1 reductions on the images in 'night1' directory and put
;	results in 'night1/redux':
;
;	KCWI_PREP,'night1','night1/redux'
;	KCWI_STAGE1,'night1/redux/kcwi.proc'
;
; MODIFICATION HISTORY:
;	Written by:	Don Neill (neill@caltech.edu)
;	2013-MAY-10	Initial version
;	2013-MAY-16	Added KCWI_LA_COSMIC call to clean image of CRs
;	2013-JUL-02	Handles case when no bias frames were taken
;			Made final output image *_int.fits for all input imgs
;	2013-JUL-09	Reject cosmic rays for continuum lamp obs
;	2013-JUL-16	Now uses kcwi_stage1_prep to do the bookkeeping
;	2013-AUG-09	Writes out sky image for nod-and-shuffle observations
;	2013-SEP-10	Changes cr sigclip for cflat images with nasmask
;	2014-APR-03	Uses master ppar and link files
;	2014-APR-06	Now makes mask and variance images for all types
;	2014-MAY-01	Handles aborted nod-and-shuffle observations
;	2014-SEP-29	Added infrastructure to handle selected processing
;	2017-APR-15	Added cosmic ray exposure time threshhold (60s)
;	2017-MAY-24	Changed to proc control file and removed link file
;-
pro kcwi_stage1,procfname,ppfname,help=help,verbose=verbose, display=display
	;
	; setup
	pre = 'KCWI_STAGE1'
	startime=systime(1)
	crexthresh = 2.
	q = ''	; for queries
	;
	; help request
	if keyword_set(help) then begin
		print,pre+': Info - Usage: '+pre+', Proc_filespec, Ppar_filespec'
		print,pre+': Info - default filespecs usually work (i.e., leave them off)'
		return
	endif
	;
	; get ppar struct
	ppar = kcwi_read_ppar(ppfname)
	;
	; verify ppar
	if kcwi_verify_ppar(ppar,/init) ne 0 then begin
		print,pre+': Error - pipeline parameter file not initialized: ',ppfname
		return
	endif
	;
	; verify directories
	if kcwi_verify_dirs(ppar,rawdir,reddir,cdir,ddir,/nocreate) ne 0 then begin
		kcwi_print_info,ppar,pre,'Directory error, returning',/error
		return
	endif
	;
	; check keyword overrides
	if n_elements(verbose) eq 1 then $
		ppar.verbose = verbose
	if n_elements(display) eq 1 then $
		ppar.display = display
	;
	; log file
	lgfil = reddir + 'kcwi_stage1.log'
	filestamp,lgfil,/arch
	openw,ll,lgfil,/get_lun
	ppar.loglun = ll
	printf,ll,'Log file for run of '+pre+' on '+systime(0)
	printf,ll,'DRP Ver: '+kcwi_drp_version()
	printf,ll,'Raw dir: '+rawdir
	printf,ll,'Reduced dir: '+reddir
	printf,ll,'Calib dir: '+cdir
	printf,ll,'Data dir: '+ddir
	printf,ll,'Filespec: '+ppar.filespec
	printf,ll,'Ppar file: '+ppfname
	printf,ll,'Min oscan pix: '+strtrim(string(ppar.minoscanpix),2)
	if ppar.crzap eq 0 then begin
		printf,ll,'No cosmic ray rejection performed'
	endif else begin
		printf,ll,'Cosmic ray PSF model: '+ppar.crpsfmod
		printf,ll,'Cosmic ray PSF FWHM (px): ',ppar.crpsffwhm
		printf,ll,'Cosmic ray PSF size (px): ',ppar.crpsfsize
	endelse
	if ppar.nassub eq 0 then $
		printf,ll,'No nod-and-shuffle sky subtraction performed'
	if ppar.saveintims eq 1 then $
		printf,ll,'Saving intermediate images'
	if ppar.includetest eq 1 then $
		printf,ll,'Including test images in processing'
	if ppar.clobber then $
		printf,ll,'Clobbering existing images'
	printf,ll,'Verbosity level   : ',ppar.verbose
	printf,ll,'Display level     : ',ppar.display
	;
	; read proc file
	kpars = kcwi_read_proc(ppar,procfname,imgnum,count=nproc)
	;
	; plot status
	doplots = (ppar.display ge 1)
	;
	; gather configuration data on each observation in rawdir
	kcwi_print_info,ppar,pre,'Number of input images',nproc
	;
	; loop over images
	for i=0,nproc-1 do begin
		;
		; raw image to process
		obfil = kcwi_get_imname(kpars[i],imgnum[i],/raw,/exist)
		kcfg = kcwi_read_cfg(obfil)
		;
		; final reduced output file
		ofil = kcwi_get_imname(kpars[i],imgnum[i],'_int',/reduced)
		;
		; trim image type
		kcfg.imgtype = strtrim(kcfg.imgtype,2)
		;
		; check if file exists or if we want to overwrite it
		if kpars[i].clobber eq 1 or not file_test(ofil) then begin
			;
			; print image summary
			kcwi_print_cfgs,kcfg,imsum,/silent
			if strlen(imsum) gt 0 then begin
				for k=0,1 do junk = gettok(imsum,' ')
				imsum = string(i+1,'/',nproc,format='(i3,a1,i3)')+' '+imsum
			endif
			print,""
			print,imsum
			printf,ll,""
			printf,ll,imsum
			flush,ll
			;
			; record input file
			kcwi_print_info,ppar,pre,'input raw file',obfil,format='(a,a)'
			;
			; read in image
			img = mrdfits(obfil,0,hdr,/fscale,/silent)
			;
			; update header
			sxaddpar,hdr,'HISTORY','  '+kcwi_drp_version()
			sxaddpar,hdr,'HISTORY','  '+pre+' '+systime(0)
			;
			; get dimensions
			sz = size(img,/dimension)
			;
			; create mask
			msk = bytarr(sz)
			;
			; flag saturated pixels
			sat = where(img ge 65535, nsat)
			if nsat gt 0 then $
				msk[sat] = 1b $
			else	msk[0] = 1b	; to be sure scaling of output image works
			;
			; update header
			sxaddpar,hdr,'NSATPIX',nsat,' Number of saturated pixels'
			;
			; log
			kcwi_print_info,ppar,pre,'Number of saturated pixels flagged',nsat,format='(a,i9)'
			;
			; get ccd geometry
			kcwi_map_ccd,hdr,asec,bsec,dsec,tsec,direc,namps=namps,trimmed_size=tsz,verbose=kpars[i].verbose
			;
			; check amps
			if namps le 0 then begin
				kcwi_print_info,ppar,pre,'no amps found for image, check NVIDINP hdr keyword',/error
				free_lun,ll
				return
			endif
			;
			; log
			kcwi_print_info,ppar,pre,'number of amplifiers',namps
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-A: BIAS SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; initialize master bias readnoise to default value
			mbias_rn = fltarr(4) + kpars[i].readnoise
			;
			; set default values
			mbias = 0.
			avrn = kpars[i].readnoise
			;
			; do we have a master bias file?
			do_bias = (1 eq 0)	; assume no to begin with
			if strtrim(kpars[i].masterbias,2) ne '' then begin
				;
				; master bias file name
				mbfile = kpars[i].masterbias
				;
				; master bias image ppar filename
				mbppfn = repstr(mbfile,'.fits','.ppar')
				;
				; check access
				if file_test(mbppfn) then begin
					do_bias = (1 eq 1)
					;
					; log that we got it
					kcwi_print_info,ppar,pre,'bias file = '+mbfile
				endif else begin
					;
					; log that we haven't got it
					kcwi_print_info,ppar,pre,'bias file not found: '+mbfile,/error
				endelse
			endif
			;
			; let's read in or create master bias
			if do_bias then begin
				;
				; build master bias if necessary
				if not file_test(mbfile) then begin
					;
					; build master bias
					bpar = kcwi_read_ppar(mbppfn)
					bpar.loglun  = kpars[i].loglun
					bpar.verbose = kpars[i].verbose
					bpar.display = kpars[i].display
					kcwi_make_bias,bpar
				endif
				;
				; read in master bias
				mbias = mrdfits(mbfile,0,mbhdr,/fscale,/silent)
				;
				; loop over master bias amps and get read noise value(s)
				nba = sxpar(mbhdr,'NVIDINP')
				avrn = 0.
				for ia=0,nba-1 do begin
					mbias_rn[ia] = sxpar(mbhdr,'BIASRN'+strn(ia+1))
					sxaddpar,hdr,'BIASRN'+strn(ia+1),mbias_rn[ia],' amp'+strn(ia+1)+' RN in e- from bias'
					avrn = avrn + mbias_rn[ia]
				endfor
				avrn = avrn / float(nba)
				;
				; compare number of amps
				if nba ne namps then begin
					kcwi_print_info,ppar,pre,'amp number mis-match (bias vs. obs)',nba,namps,/warning
					;
					; handle mis-match
					case nba of
						1: mbias_rn[1:3] = mbias_rn[0]		; set all to single-amp value
						2: begin
							mbias_rn[2] = mbias_rn[0]	; set ccd halves to be the same
							mbias_rn[3] = mbias_rn[1]
						end
						else:					; all other cases are OK as is
					endcase
				endif
				;
				; update header
				fdecomp,mbfile,disk,dir,root,ext
				sxaddpar,hdr,'BIASSUB','T',' bias subtracted?'
				sxaddpar,hdr,'MBFILE',root+'.'+ext,' master bias file subtracted'
			;
			; handle the case when no bias frames were taken
			endif else begin
				kcwi_print_info,ppar,pre,'cannot associate with any master bias: '+kcfg.obsfname,/warning
				sxaddpar,hdr,'BIASSUB','F',' bias subtracted?'
			endelse
			;
			; subtract bias
			img = img - mbias
			;
			; output file, if requested and if bias subtracted
			if kpars[i].saveintims eq 1 and do_bias then begin
				ofil = kcwi_get_imname(kpars[i],imgnum[i],'_b',/nodir)
				kcwi_write_image,img,hdr,ofil,kpars[i]
			endif
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-A: BIAS SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-B: OVERSCAN SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; number of overscan pixels in each row
			oscan_pix = bsec[0,0,1] - bsec[0,0,0]
			;
			; do we have enough overscan to get good statistics?
			if oscan_pix ge kpars[i].minoscanpix then begin
				;
				; loop over amps
				for ia = 0, namps-1 do begin
					;
					; overscan x range - buffer avoids edge effects
					osx0	= bsec[ia,0,0] + kpars[i].oscanbuf
					osx1	= bsec[ia,0,1] - kpars[i].oscanbuf
					;
					; range in x to subtract overscan from
					dsx0	= dsec[ia,0,0]
					dsx1	= dsec[ia,0,1]
					;
					; row range (y)
					osy0	= bsec[ia,1,0]
					osy1	= bsec[ia,1,1]
					;
					; collapse each row
					osvec = median(img[osx0:osx1,osy0:osy1],dim=1)
					nx = n_elements(osvec)
					xx = findgen(nx) + osy0
					mo = moment(osvec)
					mnos = mo[0]
					sdos = sqrt(mo[1])
					yrng = [mnos-sdos*3.,mnos+sdos*3.]
					;
					; check order of fit
					if namps lt 4 then $
						order = 7 $
					else	order = 2
					;
					; fit overscan vector
					;
					; don't let first read pixels skew the fit (they can be high)
					; are we reading out so that larger y-values are read out first?
					if direc[ia,1] lt 0 then begin
						res = polyfit(xx[0:nx-50],osvec[0:nx-50],order)
					;
					; reading out so that smaller y-values are read out first
					endif else begin
						res = polyfit(xx[49:*],osvec[49:*],order)
					endelse
					osfit = poly(xx,res)
					resid = osvec - osfit
					mo = moment(resid)
					mnrs = mo[0]
					sdrs = sqrt(mo[1])
					;
					; get readnoise
					if not sxpar(hdr,'BIASSUB') then begin
						kcwi_print_info,ppar,pre,'Using overscan for computing readnoise'
						mbias_rn[ia] = sdrs
					endif
					sxaddpar,hdr,'OSCNRN'+strn(ia+1),sdrs,' amp'+strn(ia+1)+' RN in e- from oscan'
					;
					; plot if display set
					if doplots then begin
						deepcolor
						!p.background=colordex('white')
						!p.color=colordex('black')
						plot,xx,osvec,/xs,psym=1,xtitle='ROW',ytitle='<DN>', $
							title='Amp/Namps: '+strn(ia+1)+'/'+strn(namps)+ $
							', Oscan Cols: '+strn(osx0)+' - '+strn(osx1)+ $
							', Image: '+strn(imgnum[i]), $
							yran=yrng,/ys, $
							charth=2,charsi=1.5,xthi=2,ythi=2
						oplot,xx,osfit,thick=2,color=colordex('green')
						kcwi_legend,['Resid RMS: '+string(sqrt(mo[1]),form='(f5.1)')+$
							' DN'],box=0,charthi=2,charsi=1.5,/right,/bottom
					endif
					;
					; loop over rows
					for iy = osy0,osy1 do begin
						;
						; get oscan fit value at row iy
						ip = where(xx eq iy, nip)
						if nip eq 1 then begin
							osval = osfit[ip[0]]
						endif else begin
							kcwi_print_info,ppar,pre,'no corresponding overscan pixel for row',iy,/warning
							osval = 0.
						endelse
						;
						; apply over entire amp range
						img[dsx0:dsx1,iy] = img[dsx0:dsx1,iy] - osval
					endfor
					;
					; log
					kcwi_print_info,ppar,pre,'overscan readnoise in e- for amp '+strn(ia+1), sdrs,form='(a,f9.3)'
					kcwi_print_info,ppar,pre,'overscan '+strtrim(string(ia+1),2)+'/'+ $
						strtrim(string(namps),2)+' (x0,x1,y0,y1): '+ $
						    strtrim(string(osx0),2)+','+strtrim(string(osx1),2)+ $
						','+strtrim(string(osy0),2)+','+strtrim(string(osy1),2)
					kcwi_print_info,ppar,pre,'overscan '+strtrim(string(ia+1),2)+'/'+ $
						strtrim(string(namps),2)+' (<os>, sd os, <resid>, sd resid): '+ $
						     strtrim(string(mnos),2)+', '+strtrim(string(sdos),2) + $
						', '+strtrim(string(mnrs),2)+', '+strtrim(string(sdrs),2)
					;
					; make interactive if display greater than 1
					if doplots and kpars[i].display ge 2 then begin
						q = ''
						read,'Next? (Q-quit plotting, <cr>-next): ',q
						if strupcase(strmid(q,0,1)) eq 'Q' then doplots = 0
					endif
				endfor	; loop over amps
				;
				; update header
				sxaddpar,hdr,'OSCANSUB','T',' overscan subtracted?'
				;
				; output file, if requested
				if kpars[i].saveintims eq 1 then begin
					ofil = kcwi_get_imname(kpars[i],imgnum[i],'_o',/nodir)
					kcwi_write_image,img,hdr,ofil,kpars[i]
				endif
			endif else begin	; not doing oscan sub
				kcwi_print_info,ppar,pre,'not enough overscan pixels to subtract', $
					oscan_pix,/warning
				kcwi_print_info,ppar,pre,'using default readnoise',kpars[i].readnoise,/warning
				sxaddpar,hdr,'OSCANSUB','F',' overscan subtracted?'
			endelse
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-B: OVERSCAN SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-C: IMAGE TRIMMING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; create trimmed array
			imgo = fltarr(tsz[0],tsz[1])
			msko = bytarr(tsz[0],tsz[1])
			;
			; loop over amps
			for ia = 0, namps-1 do begin
				;
				; input ranges
				xi0 = dsec[ia,0,0]
				xi1 = dsec[ia,0,1]
				yi0 = dsec[ia,1,0]
				yi1 = dsec[ia,1,1]
				;
				; output ranges
				xo0 = tsec[ia,0,0]
				xo1 = tsec[ia,0,1]
				yo0 = tsec[ia,1,0]
				yo1 = tsec[ia,1,1]
				;
				; copy into trimmed image
				imgo[xo0:xo1,yo0:yo1] = img[xi0:xi1,yi0:yi1]
				msko[xo0:xo1,yo0:yo1] = msk[xi0:xi1,yi0:yi1]
				;
				; update header using 1-bias indices
				sec = '['+strn(xo0+1)+':'+strn(xo1+1)+',' + $
					  strn(yo0+1)+':'+strn(yo1+1)+']'
				sxaddpar,hdr,'ATSEC'+strn(ia+1),sec,' trimmed section for amp'+strn(ia+1), $
					after='ASEC'+strn(ia+1)
				;
				; remove old sections, no longer valid
				sxdelpar,hdr,'ASEC'+strn(ia+1)
				sxdelpar,hdr,'BSEC'+strn(ia+1)
				sxdelpar,hdr,'CSEC'+strn(ia+1)
				sxdelpar,hdr,'DSEC'+strn(ia+1)
				sxdelpar,hdr,'TSEC'+strn(ia+1)
			endfor	; loop over amps
			;
			; store trimmed image
			img = imgo
			msk = msko
			sz = size(img,/dimension)
			;
			; update header
			sxaddpar,hdr,'IMGTRIM','T',' image trimmed?'
			sxdelpar,hdr,'ROISEC'	; no longer valid
			;
			; log
			kcwi_print_info,ppar,pre,'trimmed image size: '+strtrim(string(sz[0]),2)+'x'+strtrim(string(sz[1]),2)
			;
			; output file, if requested
			if kpars[i].saveintims eq 1 then begin
				ofil = kcwi_get_imname(kpars[i],imgnum[i],'_t',/nodir)
				kcwi_write_image,img,hdr,ofil,kpars[i]
			endif
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-C: IMAGE TRIMMING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-D: GAIN CORRECTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; loop over amps
			gainstr = ''
			for ia = 0, namps-1 do begin
				;
				; get gain
				gain = sxpar(hdr,'GAIN'+strn(ia+1), count=ngn)
				if ngn le 0 then begin
					gain = sxpar(hdr,'CCDGAIN', count=ngn)
					if ngn le 0 then begin
						gain = 1.0
						kcwi_print_info,ppar,pre, $
							'no gain KW found, setting gain=1',/warning
					endif else $
						kcwi_print_info,ppar,pre, $
							'using CCDGAIN KW for gain',/warning
				endif

				gainstr = gainstr + string(gain,form='(f6.3)')+' '
				;
				; output ranges
				xo0 = tsec[ia,0,0]
				xo1 = tsec[ia,0,1]
				yo0 = tsec[ia,1,0]
				yo1 = tsec[ia,1,1]
				;
				; gain correct data
				img[xo0:xo1,yo0:yo1] = img[xo0:xo1,yo0:yo1] * gain
			endfor
			;
			; update header
			sxaddpar,hdr,'GAINCOR','T',' gain corrected?'
			sxaddpar,hdr,'BUNIT','electrons',' brightness units'
			;
			; log
			kcwi_print_info,ppar,pre,'amplifier gains (e/DN)',gainstr, format='(a,1x,a)'
			;
			; output gain-corrected image
			if kpars[i].saveintims eq 1 then begin
				ofil = kcwi_get_imname(kpars[i],imgnum[i],'_e',/nodir)
				kcwi_write_image,img,hdr,ofil,kpars[i]
			endif
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-D: GAIN CORRECTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-E: IMAGE DEFECT CORRECTION AND MASKING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; start with no bad pixels
			nbpix = 0
			bpx = [0]
			bpy = [0]
			;
			; get defect list
			bcfil = !KCWI_DATA + 'badcol_' + strtrim(kcfg.ampmode,2) + '_' + $
				strn(kcfg.xbinsize) + 'x' + strn(kcfg.ybinsize) + '.dat'
			if file_test(bcfil) then begin
				;
				; report the bad col file
				kcwi_print_info,ppar,pre,'using bad column file: '+bcfil
				;
				; read it
				readcol,bcfil,bcx0,bcx1,bcy0,bcy1,form='i,i,i,i',comment='#',/silent
				;
				; correct to IDL zero bias
				bcx0 -= 1
				bcx1 -= 1
				bcy0 -= 1
				bcy1 -= 1
				;
				; x range for bad columns
				bcdel = 5
				;
				; number of bad column entries
				nbc = n_elements(bcx0)
				for j = 0,nbc-1 do begin
					if bcx0[j] ge bcdel and bcx0[j] lt sz[0]-bcdel and $
					   bcx1[j] ge bcdel and bcx1[j] lt sz[0]-bcdel and $
				   	   bcy0[j] ge 0 and bcy0[j] lt sz[1] and $
					   bcy1[j] ge 0 and bcy1[j] lt sz[1] then begin
					   	;
					   	; number of x pixels we are fixin'
						nx = (bcx1[j] - bcx0[j]) + 1
						;
						; now do the job!
						for by = bcy0[j],bcy1[j] do begin
							;
							; get median of the +- del pixels straddling baddies
							vals = [img[bcx0[j]-bcdel:bcx0[j]-1,by], $
								img[bcx0[j]+1:bcx0[j]+bcdel,by]]
							gval = median(vals)
							;
							; substitute good value in and set mask
							for bx = bcx0[j],bcx1[j] do begin
								img[bx,by] = gval
								msk[bx,by] += 2b
								nbpix += nx
							endfor
						endfor
						;
						; log

			   		endif else begin
						kcwi_print_info,ppar,pre,'bad range for bad column!',/warning
					endelse
				endfor
				sxaddpar,hdr,'BPCLEAN','T',' cleaned bad pixels?'
				sxaddpar,hdr,'BPFILE',bcfil,' bad pixel map filename'
			endif else begin
				sxaddpar,hdr,'BPCLEAN','F',' cleaned bad pixels?'
				kcwi_print_info,ppar,pre, 'no bad column file for ' + $
					strtrim(kcfg.ampmode,2) + ' ' + $
					strn(kcfg.xbinsize) + 'x' + strn(kcfg.ybinsize)
			endelse
			;
			; update header
			sxaddpar,hdr,'NBPCLEAN',nbpix,' number of bad pixels cleaned'
			;
			; log
			kcwi_print_info,ppar,pre,'number of bad pixels = '+strtrim(string(nbpix),2)
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-E: IMAGE DEFECT CORRECTION AND MASKING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-F: COSMIC RAY REJECTION AND MASKING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; ONLY perform next step on OBJECT, DARK, and DFLAT images (and if requested)
			if (strmatch(kcfg.imgtype,'object') eq 1 or $
			    strmatch(kcfg.imgtype,'dark') eq 1 or $
			    strmatch(kcfg.imgtype,'dflat') eq 1) and kpars[i].crzap eq 1 then begin
			    	;
			    	; default sigclip
			    	sigclip = 4.5
				;
				; test for cflat and nasmask
				if strmatch(kcfg.imgtype,'cflat') eq 1 then begin
					if kcfg.nasmask eq 1 then $
						sigclip = 10.0 $
					else	sigclip = 7.0
				endif
				;
				; test for short exposures
				if strmatch(kcfg.imgtype,'object') eq 1 then begin
					if kcfg.xposure lt 300. then $
						sigclip = 10. $
					else	sigclip = 4.5
				endif
				;
				; check exposure threshhold
				if kcfg.xposure gt crexthresh then begin
					;
					; call kcwi_la_cosmic
					kcwi_la_cosmic,img,kpars[i],crmsk,readn=avrn,gain=1.,objlim=4., $
						sigclip=sigclip,ntcosmicray=ncrs, $
						psfmodel=kpars[i].crpsfmod, $
						psffwhm=kpars[i].crpsffwhm, $
						psfsize=kpars[i].crpsfsize, $
						bigkernel=kpars[i].crbigkern, $
						bigykernel=kpars[i].crbigykern
					;
					; update main header
					sxaddpar,hdr,'CRCLEAN','T',' cleaned cosmic rays?'
					sxaddpar,hdr,'NCRCLEAN',ncrs,' number of cosmic rays cleaned'
					if kpars[i].crbigykern then $
						sxaddpar,hdr,'CRKERN','5x5asymY',' cosmic ray kernel' $
					else if kpars[i].crbigkern then $
						sxaddpar,hdr,'CRKERN','5x5',' cosmic ray kernel' $
					else	sxaddpar,hdr,'CRKERN','3x3',' cosmic ray kernel'
					if kpars[i].crpsfmod ne '' then begin
						sxaddpar,hdr,'CRPSFMOD',kpars[i].crpsfmod,' CR object PSF model'
						sxaddpar,hdr,'CRPSFSIZ',kpars[i].crpsfsize,' CR object PSF size (px)'
						sxaddpar,hdr,'CRPSFWHM',kpars[i].crpsffwhm,' CR object PSF FWHM (px)'
					endif
					sxaddpar,hdr,'HISTORY','  KCWI_LA_COSMIC '+systime(0)
					;
					; write out cleaned object image
					if kpars[i].saveintims eq 1 then begin
						ofil = kcwi_get_imname(kpars[i],imgnum[i],'_cr',/nodir)
						kcwi_write_image,img,hdr,ofil,kpars[i]
					endif
					;
					; update mask image
					cpix = where(crmsk eq 1, ncpix)
					if ncpix gt 0 then msk[cpix] += 4b
					;
					; update CR mask header
					mskhdr = hdr
					sxdelpar,mskhdr,'BUNIT'
					sxaddpar,mskhdr,'BSCALE',1.
					sxaddpar,mskhdr,'BZERO',0
					sxaddpar,mskhdr,'MASKIMG','T',' mask image?'
					;
					; write out CR mask image
					if kpars[i].saveintims eq 1 then begin
						ofil = kcwi_get_imname(kpars[i],imgnum[i],'_crmsk',/nodir)
						kcwi_write_image,msk,mskhdr,ofil,kpars[i]
					endif
				endif else begin
					;
					; not cosmic ray cleaned: below exposure threshhold
					kcwi_print_info,ppar,pre, $
						'cosmic ray cleaning skipped, exposure time <= ', $
						crexthresh,format='(a,f6.1)',/info
					sxaddpar,hdr,'CRCLEAN','F',' cleaned cosmic rays?'
					;
					; update CR mask header
					mskhdr = hdr
					sxdelpar,mskhdr,'BUNIT'
					sxaddpar,mskhdr,'BSCALE',1.
					sxaddpar,mskhdr,'BZERO',0
					sxaddpar,mskhdr,'MASKIMG','T',' mask image?'
				endelse
			endif else begin
				if kpars[i].crzap ne 1 then $
					kcwi_print_info,ppar,pre,'cosmic ray cleaning skipped',/warning
				sxaddpar,hdr,'CRCLEAN','F',' cleaned cosmic rays?'
				;
				; update CR mask header
				mskhdr = hdr
				sxdelpar,mskhdr,'BUNIT'
				sxaddpar,mskhdr,'BSCALE',1.
				sxaddpar,mskhdr,'BZERO',0
				sxaddpar,mskhdr,'MASKIMG','T',' mask image?'
			endelse
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-F: COSMIC RAY REJECTION AND MASKING
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-G: CREATE VARIANCE IMAGE
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; Poisson variance is electrons per pixel
			var = img
			varhdr = hdr
			;
			; loop over amps
			for ia = 0, namps-1 do begin
				;
				; output ranges
				xo0 = tsec[ia,0,0]
				xo1 = tsec[ia,0,1]
				yo0 = tsec[ia,1,0]
				yo1 = tsec[ia,1,1]
				;
				; variance is electrons + RN^2
				var[xo0:xo1,yo0:yo1] = (img[xo0:xo1,yo0:yo1]>0) + mbias_rn[ia]^2
			endfor
			avvar = avg(var)
			;
			; update header
			sxaddpar,varhdr,'VARIMG','T',' variance image?'
			sxaddpar,varhdr,'BUNIT','variance',' brightness units'
			;
			; log
			kcwi_print_info,ppar,pre,'average variance (e-) = '+strtrim(string(avvar),2)
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-G: CREATE VARIANCE IMAGE
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-H: NOD-AND-SHUFFLE SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; ONLY perform next step on OBJECT images
			if kpars[i].nassub eq 1 and strmatch(kcfg.imgtype,'object') eq 1 and $
				kcfg.nasmask eq 1 and kcfg.shuffmod eq 1 then begin
				;
				; check panel limits
				if kcfg.nsskyr0 le 0 then $
					kcwi_print_info,ppar,pre,'are nod-and-shuffle panel limits 1-biased?',/warning
				;
				; get panel limits, convert to 0-bias
				skyrow0 = (kcfg.nsskyr0 - 1) > 0
				skyrow1 = (kcfg.nsskyr1 - 1) > 0
				objrow0 = (kcfg.nsobjr0 - 1) > 0
				objrow1 = (kcfg.nsobjr1 - 1) > 0
				;
				; check limits
				if (skyrow1-skyrow0) eq (objrow1-objrow0) then begin
					;
					; create intermediate images
					sky = img
					obj = img
					;
					; sky in the bottom third (normal nod-and-shuffle config)
					if skyrow0 lt 10 then begin
						;
						; get variance and mask images
						skyvar = var
						skymsk = msk
						;
						; move sky to object position
						sky[*,objrow0:objrow1] = img[*,skyrow0:skyrow1]
						skyvar[*,objrow0:objrow1] = var[*,skyrow0:skyrow1]
						skymsk[*,objrow0:objrow1] = msk[*,skyrow0:skyrow1]
						;
						; do subtraction
						img = img - sky
						var = var + skyvar
						msk = msk + skymsk
						;
						; clean images
						img[*,skyrow0:skyrow1] = 0.
						img[*,objrow1+1:*] = 0.
						var[*,skyrow0:skyrow1] = 0.
						var[*,objrow1+1:*] = 0.
						msk[*,skyrow0:skyrow1] = 0b
						msk[*,objrow1+1:*] = 0b
						sky[*,skyrow0:skyrow1] = 0.
						sky[*,objrow1+1:*] = 0.
						obj[*,skyrow0:skyrow1] = 0.
						obj[*,objrow1+1:*] = 0.
					;
					; sky is in middle third (aborted nod-and-shuffle during sky obs)
					endif else begin
						;
						; log non-standard reduction
						kcwi_print_info,ppar,pre,'non-standard nod-and-shuffle configuration: sky in center third',/warning
						;
						; get variance and mask images
						objvar = var
						objmsk = msk
						;
						; move obj to sky position
						obj[*,skyrow0:skyrow1] = img[*,objrow0:objrow1]
						objvar[*,skyrow0:skyrow1] = var[*,objrow0:objrow1]
						objmsk[*,skyrow0:skyrow1] = msk[*,objrow0:objrow1]
						;
						; do subtraction
						img = obj - img
						var = var + objvar
						msk = msk + objmsk
						;
						; clean images
						img[*,objrow0:objrow1] = 0.
						img[*,0:skyrow0-1] = 0.
						var[*,objrow0:objrow1] = 0.
						var[*,0:skyrow0-1] = 0.
						msk[*,objrow0:objrow1] = 0b
						msk[*,0:skyrow0-1] = 0b
						sky[*,objrow0:objrow1] = 0.
						sky[*,0:skyrow0-1] = 0.
						obj[*,objrow0:objrow1] = 0.
						obj[*,0:skyrow0-1] = 0.
					endelse
					;
					; update headers
					skyhdr = hdr
					objhdr = hdr
					sxaddpar,objhdr,'NASSUB','F',' Nod-and-shuffle subtraction done?'
					sxaddpar,skyhdr,'NASSUB','F',' Nod-and-shuffle subtraction done?'
					sxaddpar,skyhdr,'SKYOBS','T',' Sky observation?'
					sxaddpar,hdr,'NASSUB','T',' Nod-and-shuffle subtraction done?'
					sxaddpar,varhdr,'NASSUB','T',' Nod-and-shuffle subtraction done?'
					sxaddpar,mskhdr,'NASSUB','T',' Nod-and-shuffle subtraction done?'
					;
					; log
					kcwi_print_info,ppar,pre,'nod-and-shuffle subtracted, rows (sky0,1, obj0,1)', $
						skyrow0,skyrow1,objrow0,objrow1,format='(a,4i6)'
					;
					; write out sky image
					ofil = kcwi_get_imname(kpars[i],imgnum[i],'_sky',/nodir)
					kcwi_write_image,sky,skyhdr,ofil,kpars[i]
					;
					; write out obj image
					ofil = kcwi_get_imname(kpars[i],imgnum[i],'_obj',/nodir)
					kcwi_write_image,obj,objhdr,ofil,kpars[i]
				endif else $
					kcwi_print_info,ppar,pre, $
						'nod-and-shuffle sky/obj row mismatch (no subtraction done)',/warning
				;
				; nod-and-shuffle subtraction requested for object
			endif else begin
				;
				; nod-and-shuffle _NOT_ requested for object
				if strmatch(kcfg.imgtype,'object') eq 1 and $
					kcfg.nasmask eq 1 and kcfg.shuffmod eq 1 then $
						kcwi_print_info,ppar,pre, $
						'nod-and-shuffle sky subtraction skipped for nod-and-shuffle image', $
						/warning
			endelse
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-H: NOD-AND-SHUFFLE SUBTRACTION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; BEGIN STAGE 1-I: IMAGE RECTIFICATION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; get ampmodes that require rectification
			ampmode = strupcase(strtrim(kcfg.ampmode,2))
			if ampmode eq '__D' or ampmode eq '__F' or ampmode eq '__B' or ampmode eq '__G' or $
			   ampmode eq '__A' or ampmode eq '__H' or ampmode eq 'TUP' then begin
				;
			   	; Upper Right Amp
			   	if ampmode eq '__B' or ampmode eq '__G' then begin
					img = rotate(img, 2)
					msk = rotate(msk, 2)
					var = rotate(var, 2)
				endif
				;
				;  Lower Right Amp
				if ampmode eq '__D' or ampmode eq '__F' then begin
					img = rotate(img, 5)
					msk = rotate(msk, 5)
					var = rotate(var, 5)
				endif
				;
				; Upper Left Amp
				if ampmode eq '__A' or ampmode eq '__H' then begin
					img = rotate(img, 7)
					msk = rotate(msk, 7)
					var = rotate(var, 7)
				endif
				;
				; Upper two Amps
				if ampmode eq 'TUP' then begin
					img = rotate(img, 7)
					msk = rotate(msk, 7)
					var = rotate(var, 7)
				endif
		   	endif 
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			; END   STAGE 1-I: IMAGE RECTIFICATION
			;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
			;
			; write out mask image
			ofil = kcwi_get_imname(kpars[i],imgnum[i],'_msk',/nodir)
			kcwi_write_image,msk,mskhdr,ofil,kpars[i]
			;
			; output variance image
			ofil = kcwi_get_imname(kpars[i],imgnum[i],'_var',/nodir)
			kcwi_write_image,var,varhdr,ofil,kpars[i]
			;
			; write out final intensity image
			ofil = kcwi_get_imname(kpars[i],imgnum[i],'_int',/nodir)
			kcwi_write_image,img,hdr,ofil,kpars[i]
		;
		; end check if output file exists already
		endif else begin
			kcwi_print_info,ppar,pre,'file not processed: '+obfil+' type: '+kcfg.imgtype,/warning
			if kpars[i].clobber eq 0 and file_test(ofil) then $
				kcwi_print_info,ppar,pre,'processed file exists already',/warning
		endelse
	endfor	; loop over images
	;
	; report
	eltime = systime(1) - startime
	print,''
	printf,ll,''
	kcwi_print_info,ppar,pre,'run time in seconds',eltime
	kcwi_print_info,ppar,pre,'finished on '+systime(0)
	;
	; close log file
	free_lun,ll
	;
	return
end	; kcwi_stage1
