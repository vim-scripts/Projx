" File:				projx.vim
"
" Author:			M Sureshkumar
" Version:			1.1
" Last Modified:	25-Nov-2013
"
" DESCRIPTION:
"  projx is a project explorer plugin. It opens a project navigation panel on
"  the right/left side of the vim screen. When enter is pressed on a file name
"  the file is opened in a new tab or jumps to an existing tab that already
"  has the file
"
"  It supports project wide grep that will show all the instances in the
"  quickfix window. 
"
"  When enabled, it automatically creates and updates tag file for the list of
"  files in the project.
"
" USAGE:
"  To use this plugin, simply place a .projx file in the root of working directory
"  with all the file names (with relative path) in the project (one per line)
"
"  :Projx [<project file>] to open or close the project navigation panel. Optionally 
"  specify the project file name to this command.
"
"  :Pgrep <regx> to search for a string across all the files in the project. Results are
"  listed in the quickfix window. Preview/jump to the location using p or <enter> keys.
"
"  :Ptags to update the tag file. This plugin automatically updates the tag
"  file on init (if any of the file is newer than the tag file)
"
"  :Pfilter <wildcard expression> to see only the specific files on the navigation panel
"
" OPTIONS:
"  Set the following variables in .vimrc/_vimrc file to control some of the
"  options. 
"
"  let g:projx_file_def = <default project file name>  " .projx is used by
"  													   " default
"  let g:projx_right_win = <1/0>                       " use right/left navigation 
"  													   " panel
"  let g:projx_win_size = xxx						   " set the navigation panel 
"                                                      " width to xxx
"  let g:projx_ctag_path = <ctag executable name/path> " omit this to disable
"                                                      " tab file creation
"
" SHORTCUTS:
"  Some useful shortcuts to add to .vimrc/_vimrc
"   nmap <silent> <F3> :Pgrep expand("<cword>")<CR>
"   nmap <silent> <F7> :Projx<CR>
"
" INSTALL:
"  Linux/Unix/Cygwin : Copy the projx.vim to ~/.vim/plugin/
"  Windows : Copy the projx.vim to %HOME%\vimfiles\plugin\
"
" *****************************************************************************

if exists('g:projx_loaded') || &cp
    finish
endif

let g:projx_loaded=1

if !exists('g:projx_file_def')
	let g:projx_file_def = '.projx'
endif

if !exists('g:projx_win_size')
	let g:projx_win_size = 20
endif

if !exists('g:projx_right_win')
	let g:projx_right_win = 1
endif

" Script local variable to keep track of the tag explorer state information
let s:projx_bufname = '_____ProjX_____'
let s:comments = 4
let s:projx_file = ""
let s:proj_root_dir = "./"
let s:user_filter   = ''
let s:projx_win_active = 0
let s:prev_proj_file = ""
let s:prev_filter = ''
"let s:saved_view = {}

let s:file_list = []
let s:dir_list = []
let s:projx_debug = 0
let s:auto_update_tag = 0

let s:file_ix_old = -1

" DeleteStateInfo()
" Delete all variables created for a directory
function! s:DeleteStateInfo()
	unlet! s:file_list
	unlet! s:dir_list
	
	let s:file_ix_old = -1
	let s:file_list = []
	let s:dir_list = []
	let s:prev_proj_file = ""
	let s:prev_filter = ''
endfunction

function! s:GetFileName(name)
	let result = substitute(a:name, '\\','\/','g')
	let result = substitute(result, '^./', '', '')
	return result
endfunction

" CreateProjxWin()
" Create a new tag explorer window. If the window is already present, jump to
" the window
function! s:CreateProjxWin()
    " Tag explorer window name
    let bname = s:projx_bufname

    " If the window is already present, jump to the window
    let winnum = bufwinnr(bname)
    if winnum != -1
        " Jump to the existing window
        if winnr() != winnum
            exe winnum . 'wincmd w'
        endif
        return 0
    endif

	let w:file_window = 1

	" Open the window at the leftmost place
	if g:projx_right_win == 1
		let win_dir = 'botright vertical'
	else
		let win_dir = 'topleft vertical'
	endif

    " If the tag explorer temporary buffer already exists, then reuse it.
    " Otherwise create a new buffer
    let bufnum = bufnr(bname)
    if s:projx_win_active == 0 || bufnum == -1
        " Create a new buffer
        let wcmd = bname
		let existing = 0
    else
        " Edit the existing buffer
        let wcmd = '+buffer' . bufnum
		let existing = 1
    endif

    " Create the tag explorer window
    exe 'silent! ' . win_dir . ' ' . g:projx_win_size . 'split ' . wcmd

	if existing == 1
		return 0
	endif

    " Mark the buffer as a scratch buffer
    setlocal buftype=nofile
    setlocal bufhidden=delete
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " Create buffer local mappings for the tag explorer window
    nnoremap <buffer> <silent> <CR> :call <SID>ProcessSelection()<CR>
    nnoremap <buffer> <silent> ? :call <SID>ShowHelp()<CR>
    nnoremap <buffer> <silent> q :call <SID>CloseProjxWin()<CR>
    nnoremap <buffer> <silent> <space> :call <SID>ShowFilePath()<CR>

    " Highlight the comments, directories, tag types and tag names
    if has('syntax')
        syntax match ProjxComment '^\~ .*'
        highlight clear ProjxComment
        highlight link ProjxComment SpecialComment

        syntax match ProjxFileSelect 'dummy'
        highlight clear ProjxFileSelect
        highlight link ProjxFileSelect Search
    endif

    " Define the autocommands
    augroup ProjxAutoCmds
        autocmd!
        " Adjust the Vim window width when the tag explorer window is closed
        autocmd BufUnload <buffer> call s:ProjxBufUnload()
		autocmd BufEnter  <buffer> call s:ProjxBufEnter()
		autocmd TabEnter * call s:ProjxTabEnter() 
		autocmd BufEnter * call s:HighlightFile(expand("<afile>"))
	 	autocmd VimResized	<buffer> call s:ResizeWindow()
		"autocmd WinLeave  <buffer> call s:SaveView()
		"autocmd TabLeave * call s:TabLeave()
    augroup end

	let s:projx_win_active = 1

	return 1
endfunction

function! s:ResizeWindow()
    let winnum = bufwinnr(s:projx_bufname)

	if winnum == -1
		return
	endif

	let oldwin = winnr()
	if winnum != oldwin
		exe winnum . 'wincmd w'
	endif

	exe 'vertical resize ' . g:projx_win_size

	if oldwin != winnr()
		exe oldwin . 'wincmd w'
	endif
endfunction

function! s:ProjxBufUnload()
	let i = 1
	while winbufnr(i) != -1
		if getwinvar(i, 'file_window') == 1
			let fwin_num = i
			break
		endif
		let i = i + 1
	endwhile

	if fwin_num != 0
		exe fwin_num . "wincmd w"
	endif
endfunction

function! s:SaveView()
	let s:saved_view = winsaveview()
endfunction

function! s:ProjxTabEnter()
	if s:projx_win_active == 1
		let winnr = bufwinnr(s:projx_bufname) 
		if winnr == -1
			call s:OpenProjx("")
			wincmd p	
		endif
"	else
"		call s:CloseProjxWin()
	endif
endfunction

function! s:ProjxBufEnter()
	if (s:projx_win_active == 0) || (tabpagewinnr(tabpagenr(), "$") == 1)
		quit
	endif
	let @/ = ""
endfunction


" ClearPorjxWin
" Initialize the tag explorer window. Assumes the focus is already on
" the tagexplorer window
function! s:ClearPorjxWin()
    " Mark the buffer as modifiable
    setlocal modifiable

    " Set report option to a huge value to prevent informational messages
    " about the deleted lines

    " Delete the contents of the buffer to the black-hole register
    silent! %delete _

    " Restore the report option

    " Add comments at the top of the window
    call append(0, '~ Press ? for help')
    call append(1, '~ Project : ' . s:projx_file)
    call append(2, '~ Filter  : ' . s:user_filter)
    call append(3, '~ ')

    " Mark the buffer as not modifiable
    setlocal nomodifiable
endfunction

function! s:CloseProjxWin()
    silent! autocmd! ProjxAutoCmds
	let bname = s:projx_bufname
    "let winnum = bufwinnr(bname)
	"if winnum != -1
	"	exe winnum . 'wincmd w'
	"	quit
	"endif
	"
	let bufnum = bufnr(bname)
	if bufnum >= 0
		try
			silent exe bufnum . "bdelete"
		catch
		endtry
	endif
	call s:DeleteStateInfo()
    "Remove the autocommands for the tag explorer window
	let s:projx_win_active = 0
endfunction

" ShowHelp()
" Display the tag explorer help
function! s:ShowHelp()
    echo 'Project Explorer keyboard shortcuts'
    echo '-------------------------------'
    echo '<Enter> : Jump to the tag definition'
    echo '<Space> : Display the File path'
    echo 'q       : Close the tag explorer window'
endfunction


" ListProjxFiles()
" List the filenames in the specified projectfile
function! s:ListProjxFiles(proj_file)

	if s:prev_proj_file == a:proj_file && s:prev_filter == s:user_filter
		return 
	endif

	call s:DeleteStateInfo()

	let s:prev_proj_file = a:proj_file
	let s:prev_filter = s:user_filter

	let linenr = s:comments + 1
	let s:proj_root_dir = substitute(a:proj_file, '[^/]\+$','','')
	exe 'set tags=' . s:proj_root_dir . ".tags"
	let dirlist = []

	let file_filter = s:user_filter
	if file_filter =~ '^\s*$'
		let file_filter = "*"
	endif

	let file_filter = substitute(file_filter, '\.', '\\\.', 'g')
	let file_filter = substitute(file_filter, '\*', '\.\*', 'g')
	let file_filter = '^' . file_filter . '$'
	let max_ftime = getftime(a:proj_file)
	let build_tag = 0

	for line in readfile(a:proj_file, '')
		if line =~ '^\s*#'
			continue
		endif
		if line =~ '^\s'
			continue
		endif

		let fname = substitute(line,'^\s*','','')
		let fname = substitute(fname,'\s*$','','')

		if(getftype(s:proj_root_dir . fname) == "file")
			let ftime = getftime(s:proj_root_dir . fname)
			let dirname = substitute(fname, '[^/]*$','','')
			let dirname = substitute(dirname, '\/$','','')

			if ftime > max_ftime
				let max_ftime = ftime
			endif

			if dirname == ''
				let dirname = '.'
			endif

			let dirname = s:proj_root_dir . dirname

			call filter(dirlist, 'v:val != "' . dirname . '"')
			call add(dirlist,dirname)

			let fname = substitute(fname, '^.*\/','','')

			if fname != "" && fname =~ file_filter
				call add(s:file_list, fname)
				call add(s:dir_list, dirname)
				let linenr = linenr + 1
			endif
		endif
	endfor

	exe 'set path+=' . join(dirlist, ',')
	let g:clang_user_options = '-I' . join(dirlist, ' -I')

	if max_ftime > getftime(s:proj_root_dir . ".tags")
		call s:CreateTags("")
	endif

    " Clear the previously highlighted name. The line numbers will change
    " after the new directory listing is added. So the wrong name will be
    " highlighted.
    match none

	" Initialize the window
	call s:ClearPorjxWin()

    " Copy the directory list to the buffer
    setlocal modifiable

    " Set report option to a huge value to prevent informations messages
    " while deleting the lines
	
	exe s:comments

    " Compute the starting and ending line numbers for the tags
	for file in s:file_list
		put = ' ' . file . repeat(' ', g:projx_win_size - len(file))
	endfor

    setlocal nomodifiable

	exe s:comments + 1

	let i = 1
	while 1
		let wb = winbufnr(i)

		if wb == -1
			break
		endif

		if bufname(wb) != s:projx_bufname && bufname(wb) != ""
			call s:HighlightFile(bufname(wb))
			break
		endif

		let i = i + 1
	endwhile

	" if len(s:saved_view) == 0
	"	exe s:comments + 1
	" else
	"	call winrestview(s:saved_view)
	" endif
	"redraw!
endfunction

function! s:FindFileIndex(fname)
    let i = 0
	let found = -1
	let fullname = s:GetFileName(a:fname)

    while i < len(s:file_list)
		if fullname == s:GetFileName(s:dir_list[i] ."/". s:file_list[i])
			let found = i
			break
		endif
		let i = i + 1
	endwhile

	return found

endfunction

function! s:Rehighlight(file_ix)
	let line = a:file_ix + s:comments + 1

	if(line > 0)
		exec line
		call winline()
		match none
		exe 'match ProjxFileSelect /\%' . line . 'l.*/'
	endif
endfunction

function! s:HighlightFile(fname)

	let name = a:fname

	if name == "" || name == s:projx_bufname
		return
	endif

	let file_ix = s:FindFileIndex(name)

    let winnum = bufwinnr(s:projx_bufname)

	" if projx window not found - recreate it
	if winnum == -1
		let s:projx_win_active = 0
		call s:DeleteStateInfo()
		call s:OpenProjx("")
		let winnum = bufwinnr(s:projx_bufname)
		if winnum == -1
			return
		endif
	endif

	if s:file_ix_old != file_ix && file_ix >= 0
		let oldwin = winnr()
		if winnum != oldwin
			exe winnum . 'wincmd w'
		endif

		call s:Rehighlight(file_ix)

		if oldwin != winnr()
			exe oldwin . 'wincmd w'
		endif

		let s:file_ix_old = file_ix
	endif
endfunction


" ToggleWindow()
" Open/Close the tag explorer window
function! s:ToggleWindow(fname)
	if s:projx_win_active && a:fname == ""
		call s:CloseProjxWin()
	else
		call s:OpenProjx(a:fname)
	endif
endfunction

" OpenProjx()
" Open/Close the tag explorer window
function! s:OpenProjx(fname)
	if s:CheckProjFileName(a:fname) == 0
		return
	endif

	call s:CreateProjxWin()
	" List the files in the project file
	call s:ListProjxFiles(s:projx_file)
endfunction

" GetFileIndex()
" Get the file index based on the specified line number
function! s:GetFileIndex(linenr)
	return a:linenr - s:comments - 1
endfunction


" EditFile()
" Open the specified file and jump to the specified pattern
function! s:EditFile(filename)
    " If the file is opened in one of the existing windows, use that window
	
	" Locate the previously used window for opening a file
	let fwin_num = 0

	let i = 1
	while winbufnr(i) != -1
		if getwinvar(i, 'file_window') == 1
			let fwin_num = i
			break
		endif
		let i = i + 1
	endwhile

	if fwin_num != 0
		" Jump to the file window
		exe fwin_num . "wincmd w"

		let index = -1
		let empty_buf = -1
		let empty_tab = -1
		let buf_number = bufnr(a:filename)
		for i in range(tabpagenr("$"))
			let tab_file_list = tabpagebuflist(i + 1)
			let index = match(tab_file_list, "^" . buf_number . "$")
			if index != -1
				break
			endif
			if empty_buf == -1
				for buf_nr in tab_file_list
					if bufname(buf_nr) == "" && 
								\ getbufvar(buf_nr, '&modified') == 0 &&  
								\ getbufvar(buf_nr, '&buftype') == ""
						let empty_buf = buf_nr
						let empty_tab = i + 1
					endif
				endfor
			endif
		endfor

		if index != -1
			if i + 1 != tabpagenr()
				exe "tabn " . (i + 1)
				exe bufwinnr(buf_number) . "wincmd w"
			endif
		else
			if empty_buf == -1
				exe "tabe " . a:filename
			else
				exe "tabn " . empty_tab
				exe bufwinnr(empty_buf) . "wincmd w"
				exe "edit " . a:filename
			endif
		endif
	else
		" Open a new window
			" Open the window at the leftmost place
		if g:projx_right_win == 1
			let win_dir = 'topleft'
		else
			let win_dir = 'botright'
		endif

		exe win_dir . ' vnew ' a:filename
		" Go to the tag explorer window to change the window size to
		" the user configured value
		wincmd p
		exe 'vertical resize ' . g:projx_win_size
		" Go back to the file window
		wincmd p
		let w:file_window = 1
	endif

	"call s:OpenProjx("")
	"wincmd p
endfunction

" OpenFile
" Open the selected file
function! s:OpenFile(fidx)
    " Form the full pathname to the file
	if a:fidx < len(s:dir_list) && a:fidx >= 0
		let filename = s:dir_list[a:fidx] . '/' . s:file_list[a:fidx]
		" Highlight the selecte filename
		" match none
		" exe 'match TagExplorerTagName /\%' . line('.') . 'l.*/'

		" Edit the file
		call s:EditFile(filename)
	endif
endfunction


" ProcessSelection
" Process a selected entry (directory, file, or tag)
function! s:ProcessSelection()
	let fidx = s:GetFileIndex(line('.'))
	" Jump to the selected file
	call s:OpenFile(fidx)
endfunction

" ShowFilePath()
" Display the prototype for a tag
function! s:ShowFilePath()
	let fidx = s:GetFileIndex(line('.'))
	" If file name
	if fidx >= 0 && fidx < len(s:dir_list)
		echo "FilePath : " . s:dir_list[fidx] . '/' . s:file_list[fidx]
	endif
endfunction

function! s:SetFilter(filter_str)
	let s:user_filter = a:filter_str

    " Tag explorer buffer name
    let bname = s:projx_bufname

    " If tag explorer window is open then close it.
    let winnum = bufwinnr(bname)
	if winnum != -1
        " Jump to the existing window
        if winnr() != winnum
            exe winnum . 'wincmd w'
        endif

		" List the files in the project file
		call s:ListProjxFiles(s:projx_file)
	endif
endfunction

function s:GetProjxFiles()
	if s:CheckProjFileName("") == 0
		echo "Project file not specified"
		return
	endif

	let s:proj_root_dir = substitute(s:projx_file, '[^/]\+$','','')

	let list = ""

	for pfiles in readfile(s:projx_file)
		if pfiles =~ '^\s*#'
			continue
		endif
		if pfiles =~ '^\s'
			continue
		endif

		let pfiles = substitute(pfiles, '^\s*', '', '')
		let pfiles = substitute(pfiles, '\s*$', '', '')
		let pfiles = ' ' . s:proj_root_dir . pfiles
		let list = list . pfiles
	endfor

	return list
endfunction

function s:ProjxGrep(name)
	if s:CheckProjFileName("") == 0
		return
	endif
	silent exe "grep " . a:name . " " . s:GetProjxFiles()
	redraw!
	botright copen
"	set modifiable
"	silent! %s/
"	set nomodifiable
	nnoremap <buffer> <silent> p :call PreviewError()<CR>
	nnoremap <buffer> <silent> q :close<CR>
endfunction

function! PreviewError()
	let qfwin = winnr()
	.cc
	redraw
	call HlCurrentLine()
	exe qfwin . "wincmd w"
endfunction

function! s:CreateTags(fname)

	if s:CheckProjFileName("") == 0
		return
	endif

	if !exists('g:projx_ctag_path')
		return
	endif

	echo "Building Tags ..."

	let file_name =  substitute(s:projx_file, '^.*\/','','')

	if s:proj_root_dir != ""
		exe "cd " . s:proj_root_dir	
	endif

	let cmd = g:projx_ctag_path . 
		\" --excmd=pattern --tag-relative=yes --c++-kinds=+p" .
		\" --fields=+iaS --extra=+fq --sort=no -f .tags"

	if a:fname != ""
		let cmd = cmd .  " -a " . a:fname
		call system(cmd)
	else
		let cmd = cmd .  " -L -"
		let flist = ""
		for line in readfile(file_name)
			let flist = flist . substitute(line, '^\s*', '' , '') . "\n"
		endfor
		call system(cmd, flist)
		unlet flist
	endif

	if s:proj_root_dir != ""
		cd -
	endif

endfunction

function! s:CheckProjFileName(fname)
	if a:fname != ""
		let s:projx_file = a:fname
	endif

	if s:projx_file == ""
		let s:projx_file = g:projx_file_def
	endif
		
	if getftype(s:projx_file) != 'file'
		let s:projx_file = ""
		return 0
	endif

	if(s:auto_update_tag == 1)
		autocmd BufWritePost *.[ch]  call s:CreateTags(expand("<afile>"))
	    autocmd	BufWritePost *.cpp   call s:CreateTags(expand("<afile>"))
		let s:auto_update_tag = 0
	endif

	return 1

endfunction

if s:CheckProjFileName("")
	if(getftype(s:proj_root_dir . ".tags") != "file")
		call s:CreateTags("")
	endif
endif


" Define the command to open/close the tag explorer window
command -nargs=? -complete=file Projx call s:ToggleWindow(<q-args>)
command -nargs=0 Ptags call s:CreateTags("")
command -nargs=1 Pgrep call s:ProjxGrep(<q-args>)
command -nargs=? Pfilter call s:SetFilter(<q-args>)
