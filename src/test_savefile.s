  .org $e000

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "liblcd.s"


zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 52 bytes

fat32_workspace = $200      ; two pages

buffer = $400

subdirname:
  .asciiz "SUBFOLDR   "
filename:
  .asciiz "SAVETESTTXT"

reset:
  ldx #$ff
  txs

  ; Initialise
  jsr via_init
  jsr lcd_init
  jsr sd_init
  jsr fat32_init
  bcc .initsuccess
 
  ; Error during FAT32 initialization
  lda #'Z'
  jsr print_char
  lda fat32_errorstage
  jsr print_hex
  jmp loop
.initsuccess

  ; Opening Directory
  lda #'o'
  jsr print_char

  ; Open root directory
  jsr fat32_openroot

  ; Find subdirectory by name
  ldx #<subdirname
  ldy #>subdirname
  jsr fat32_finddirent
  bcc .foundsubdir

  ; Subdirectory not found
  lda #'X'
  jsr print_char
  jmp loop

.foundsubdir

  ; Open subdirectory
  jsr fat32_opendirent

  lda #'c'
  jsr print_char

  ; Check if the file exists
  ldx #<filename
  ldy #>filename
  jsr fat32_finddirent
  bcs .write

  lda #'D'
  jsr print_char

  ; It already exists, delete it.
  jsr fat32_deletefile

.write

  ; Allocating
  lda #'a'
  jsr print_char

  ; Size of example message
  lda #<(textend-text)
  sta fat32_bytesremaining
  pha
  lda #>(textend-text)
  sta fat32_bytesremaining+1
  pha

  ; Allocate space for the file
  jsr fat32_allocatefile

  ; Re-opening folder sector
  lda #'r'
  jsr print_char 

  jsr fat32_open_cd

  ; Writing dirent
  lda #'d'
  jsr print_char

  ; Restore filesize
  pla 
  sta fat32_bytesremaining+1
  pla
  sta fat32_bytesremaining

  ; Load filename ponter
  lda #<filename
  sta fat32_filenamepointer
  lda #>filename
  sta fat32_filenamepointer+1

  ; Write the directory entry
  jsr fat32_writedirent

  ; Writing Data
  lda #'w'
  jsr print_char

  ; Now write the file data
  lda #<text
  sta fat32_address
  lda #>text
  sta fat32_address+1

  jsr fat32_file_write

  ; Done!
  lda #'!'
  jsr print_char

  ; loop forever
loop:
  jmp loop

text:
  .asciiz "Hello World!",$0d,$0a,"This is text saved from a 6502 computer to an SD Card!",$0d,$0a,$00
textend:
  .byte $00

  .org $fffc
  .word reset
  .word $0000
