; FAT32/SD interface library
;
; This module requires some RAM workspace to be defined elsewhere:
;
; fat32_workspace    - a large page-aligned 512-byte workspace
; zp_fat32_variables - 52 bytes of zero-page storage for variables etc

fat32_readbuffer = fat32_workspace
; Scratch RAM for contiguous-cluster run expansion during sequential reads.
fat32_runcluster                = $05F6 ; 4 bytes

fat32_fatstart                  = zp_fat32_variables + $00  ; 4 bytes
fat32_datastart                 = zp_fat32_variables + $04  ; 4 bytes
fat32_rootcluster               = zp_fat32_variables + $08  ; 4 bytes
fat32_sectorspercluster         = zp_fat32_variables + $0c  ; 1 byte
fat32_pendingsectors            = zp_fat32_variables + $0d  ; 1 byte
fat32_address                   = zp_fat32_variables + $0e  ; 2 bytes
fat32_nextcluster               = zp_fat32_variables + $10  ; 4 bytes
fat32_bytesremaining            = zp_fat32_variables + $14  ; 4 bytes
fat32_lastfoundfreecluster      = zp_fat32_variables + $18  ; 4 bytes
fat32_filenamepointer           = zp_fat32_variables + $1c  ; 2 bytes
fat32_lastcluster               = zp_fat32_variables + $1e  ; 4 bytes
fat32_lastsector                = zp_fat32_variables + $22  ; 4 bytes
fat32_numfats                   = zp_fat32_variables + $26  ; 1 byte
fat32_filecluster               = zp_fat32_variables + $27  ; 4 bytes
fat32_sectorsperfat             = zp_fat32_variables + $2b  ; 4 bytes
fat32_cdcluster                 = zp_fat32_variables + $2f  ; 4 bytes

fat32_errorstage                = fat32_bytesremaining  ; only used during initialization

fat32_init:
  ; Initialize the module - read the MBR etc, find the partition,
  ; and set up the variables ready for navigating the filesystem

  ; Read the MBR and extract pertinent information

  lda #0
  sta fat32_errorstage

  ; Sector 0
  lda #0
  sta zp_sd_currentsector
  sta zp_sd_currentsector+1
  sta zp_sd_currentsector+2
  sta zp_sd_currentsector+3

  ; Target buffer
  lda #<fat32_readbuffer
  sta fat32_address
  sta zp_sd_address
  lda #>fat32_readbuffer
  sta fat32_address+1
  sta zp_sd_address+1

  ; Do the read
  jsr sd_readsector


  inc fat32_errorstage ; stage 1 = boot sector signature check

  ; Check some things
  lda fat32_readbuffer+510 ; Boot sector signature 55
  cmp #$55
  bne _fail
  lda fat32_readbuffer+511 ; Boot sector signature aa
  cmp #$aa
  bne _fail


  inc fat32_errorstage ; stage 2 = finding partition

  ; Find a FAT32 LBA partition, type 12 (0xc)
_FSTYPE_FAT32 = 12
  ldx #0
  lda fat32_readbuffer+$1c2,x
  cmp #_FSTYPE_FAT32
  beq _foundpart
  ldx #16
  lda fat32_readbuffer+$1c2,x
  cmp #_FSTYPE_FAT32
  beq _foundpart
  ldx #32
  lda fat32_readbuffer+$1c2,x
  cmp #_FSTYPE_FAT32
  beq _foundpart
  ldx #48
  lda fat32_readbuffer+$1c2,x
  cmp #_FSTYPE_FAT32
  beq _foundpart

_fail:
  jmp _error

_foundpart:

  ; Read the FAT32 BPB
  lda fat32_readbuffer+$1c6,x
  sta zp_sd_currentsector
  lda fat32_readbuffer+$1c7,x
  sta zp_sd_currentsector+1
  lda fat32_readbuffer+$1c8,x
  sta zp_sd_currentsector+2
  lda fat32_readbuffer+$1c9,x
  sta zp_sd_currentsector+3

  jsr sd_readsector


  inc fat32_errorstage ; stage 3 = BPB signature check

  ; Check some things
  lda fat32_readbuffer+510 ; BPB sector signature 55
  cmp #$55
  bne _fail
  lda fat32_readbuffer+511 ; BPB sector signature aa
  cmp #$aa
  bne _fail

  inc fat32_errorstage ; stage 4 = RootEntCnt check

  lda fat32_readbuffer+17 ; RootEntCnt should be 0 for FAT32
  ora fat32_readbuffer+18
  bne _fail

  inc fat32_errorstage ; stage 5 = TotSec16 check

  lda fat32_readbuffer+19 ; TotSec16 should be 0 for FAT32
  ora fat32_readbuffer+20
  bne _fail

  inc fat32_errorstage ; stage 6 = SectorsPerCluster check

  ; Check bytes per filesystem sector, it should be 512 for any SD card that supports FAT32
  lda fat32_readbuffer+11 ; low byte should be zero
  bne _fail
  lda fat32_readbuffer+12 ; high byte is 2 (512), 4, 8, or 16
  cmp #2
  bne _fail

  ; Calculate the starting sector of the FAT
  clc
  lda zp_sd_currentsector
  adc fat32_readbuffer+14    ; reserved sectors lo
  sta fat32_fatstart
  sta fat32_datastart
  lda zp_sd_currentsector+1
  adc fat32_readbuffer+15    ; reserved sectors hi
  sta fat32_fatstart+1
  sta fat32_datastart+1
  lda zp_sd_currentsector+2
  adc #0
  sta fat32_fatstart+2
  sta fat32_datastart+2
  lda zp_sd_currentsector+3
  adc #0
  sta fat32_fatstart+3
  sta fat32_datastart+3

  ; Calculate the starting sector of the data area
  ldx fat32_readbuffer+16   ; number of FATs
  stx fat32_numfats         ; (stash for later as well)
_skipfatsloop:
  clc
  lda fat32_datastart
  adc fat32_readbuffer+36 ; fatsize 0
  sta fat32_datastart
  lda fat32_datastart+1
  adc fat32_readbuffer+37 ; fatsize 1
  sta fat32_datastart+1
  lda fat32_datastart+2
  adc fat32_readbuffer+38 ; fatsize 2
  sta fat32_datastart+2
  lda fat32_datastart+3
  adc fat32_readbuffer+39 ; fatsize 3
  sta fat32_datastart+3
  dex
  bne _skipfatsloop

  ; Sectors-per-cluster is a power of two from 1 to 128
  lda fat32_readbuffer+13
  sta fat32_sectorspercluster

  ; Remember the root cluster
  lda fat32_readbuffer+44
  sta fat32_rootcluster
  lda fat32_readbuffer+45
  sta fat32_rootcluster+1
  lda fat32_readbuffer+46
  sta fat32_rootcluster+2
  lda fat32_readbuffer+47
  sta fat32_rootcluster+3

  ; Save Sectors Per FAT
  lda fat32_readbuffer+36
  sta fat32_sectorsperfat
  lda fat32_readbuffer+37
  sta fat32_sectorsperfat+1
  lda fat32_readbuffer+38
  sta fat32_sectorsperfat+2
  lda fat32_readbuffer+39
  sta fat32_sectorsperfat+3

  ; Set the last found free cluster to 0.
  lda #0
  sta fat32_lastfoundfreecluster
  sta fat32_lastfoundfreecluster+1
  sta fat32_lastfoundfreecluster+2
  sta fat32_lastfoundfreecluster+3

  ; As well as the last read clusters and sectors
  sta fat32_lastcluster
  sta fat32_lastcluster+1
  sta fat32_lastcluster+2
  sta fat32_lastcluster+3
  sta fat32_lastsector
  sta fat32_lastsector+1
  sta fat32_lastsector+2
  sta fat32_lastsector+3

  clc
  rts

_error:
  sec
  rts


fat32_seekcluster:
; Calculates the FAT sector given fat32_nextcluster and stores in zp_sd_currentsector
; Optionally will load the 512 byte FAT sector into memory at fat32_readbuffer
; If carry is set, subroutine is optimized to skip the loading if the expected
; sector is already loaded. Clearing carry before calling will skip optimization
; and force reload of the FAT sector. Once the FAT sector is loaded,
; the next cluster in the chain is loaded into fat32_nextcluster and
; zp_sd_currentsector is updated to point to the referenced data sector

; This routine also leaves Y pointing to the LSB for the 32 bit next cluster.

; Gets ready to read fat32_nextcluster, and advances it according to the FAT
; Before calling, set carry to compare the current FAT sector with lastsector.
; Otherwize, clear carry to force reading the FAT.

  php

  ; Target buffer
  lda #<fat32_readbuffer
  sta zp_sd_address
  lda #>fat32_readbuffer
  sta zp_sd_address+1

  ; FAT sector = (cluster*4) / 512 = (cluster*2) / 256
  lda fat32_nextcluster
  asl
  lda fat32_nextcluster+1
  rol
  sta zp_sd_currentsector
  lda fat32_nextcluster+2
  rol
  sta zp_sd_currentsector+1
  lda fat32_nextcluster+3
  rol
  sta zp_sd_currentsector+2
  lda #0
  sta zp_sd_currentsector+3
  ; note: cluster numbers never have the top bit set, so no carry can occur

  ; Guard against invalid cluster values: FAT sector offset must be within FAT size.
  lda zp_sd_currentsector+3
  cmp fat32_sectorsperfat+3
  bcc _cluster_ok
  bne _cluster_invalid
  lda zp_sd_currentsector+2
  cmp fat32_sectorsperfat+2
  bcc _cluster_ok
  bne _cluster_invalid
  lda zp_sd_currentsector+1
  cmp fat32_sectorsperfat+1
  bcc _cluster_ok
  bne _cluster_invalid
  lda zp_sd_currentsector
  cmp fat32_sectorsperfat
  bcc _cluster_ok
_cluster_invalid:
  plp
  jmp _invalidcluster
_cluster_ok:

  ; Add FAT starting sector
  clc
  lda zp_sd_currentsector
  adc fat32_fatstart
  sta zp_sd_currentsector
  lda zp_sd_currentsector+1
  adc fat32_fatstart+1
  sta zp_sd_currentsector+1
  lda zp_sd_currentsector+2
  adc fat32_fatstart+2
  sta zp_sd_currentsector+2
  lda #0
  adc fat32_fatstart+3
  sta zp_sd_currentsector+3

  ; Branch if we don't need to check
  plp
  bcc _newsector

  ; Check if this sector is the same as the last one
  lda fat32_lastsector
  cmp zp_sd_currentsector
  bne _newsector
  lda fat32_lastsector+1
  cmp zp_sd_currentsector+1
  bne _newsector
  lda fat32_lastsector+2
  cmp zp_sd_currentsector+2
  bne _newsector
  lda fat32_lastsector+3
  cmp zp_sd_currentsector+3
  beq _notnew

_newsector:

  ; Read the sector from the FAT
  jsr sd_readsector
  bcc :+
  jmp _invalidcluster
:

  ; Update fat32_lastsector

  lda zp_sd_currentsector
  sta fat32_lastsector
  lda zp_sd_currentsector+1
  sta fat32_lastsector+1
  lda zp_sd_currentsector+2
  sta fat32_lastsector+2
  lda zp_sd_currentsector+3
  sta fat32_lastsector+3

_notnew:

  ; Before using this FAT data, set currentsector ready to read the cluster itself
  ; We need to multiply the cluster number minus two by the number of sectors per
  ; cluster, then add the data region start sector

  ; Subtract two from cluster number
  sec
  lda fat32_nextcluster
  sbc #2
  sta zp_sd_currentsector
  lda fat32_nextcluster+1
  sbc #0
  sta zp_sd_currentsector+1
  lda fat32_nextcluster+2
  sbc #0
  sta zp_sd_currentsector+2
  lda fat32_nextcluster+3
  sbc #0
  sta zp_sd_currentsector+3

  ; Multiply by sectors-per-cluster which is a power of two between 1 and 128
  lda fat32_sectorspercluster
_spcshiftloop:
  lsr
  bcs _spcshiftloopdone
  asl zp_sd_currentsector
  rol zp_sd_currentsector+1
  rol zp_sd_currentsector+2
  rol zp_sd_currentsector+3
  jmp _spcshiftloop
_spcshiftloopdone:

  ; Add the data region start sector
  clc
  lda zp_sd_currentsector
  adc fat32_datastart
  sta zp_sd_currentsector
  lda zp_sd_currentsector+1
  adc fat32_datastart+1
  sta zp_sd_currentsector+1
  lda zp_sd_currentsector+2
  adc fat32_datastart+2
  sta zp_sd_currentsector+2
  lda zp_sd_currentsector+3
  adc fat32_datastart+3
  sta zp_sd_currentsector+3

  ; That's now ready for later code to read this sector in - tell it how many consecutive
  ; sectors it can now read
  lda fat32_sectorspercluster
  sta fat32_pendingsectors

  ; Preserve the current cluster so we can fold contiguous clusters into a
  ; single sequential run while this FAT sector is still in memory.
  lda fat32_nextcluster
  sta fat32_runcluster
  lda fat32_nextcluster+1
  sta fat32_runcluster+1
  lda fat32_nextcluster+2
  sta fat32_runcluster+2
  lda fat32_nextcluster+3
  sta fat32_runcluster+3

  ; Now go back to looking up the next cluster in the chain
  ; Find the offset to this cluster's entry in the FAT sector we loaded earlier

  ; Offset = (cluster*4) & 511 = (cluster & 127) * 4
  lda fat32_nextcluster
  and #$7f
  asl
  asl
  tay ; Y = low byte of offset

  ; Add the potentially carried bit to the high byte of the address
  lda zp_sd_address+1
  adc #0
  sta zp_sd_address+1

  ; Stash the index to next value for the cluster
  tya
  pha

  ; Copy out the next cluster in the chain for later use
  lda (zp_sd_address),y
  sta fat32_nextcluster
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+1
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+2
  iny
  lda (zp_sd_address),y
  and #$0f
  sta fat32_nextcluster+3

  ; Restore index to the table entry for the cluster
  pla
  tay

  ; See if it's the end of the chain
  lda fat32_nextcluster+3
  cmp #$0F
  bcc _notendofchain
  lda fat32_nextcluster+2
  cmp #$FF
  bne _notendofchain
  lda fat32_nextcluster+1
  cmp #$FF
  bne _notendofchain
  lda fat32_nextcluster
  cmp #$F8
  bcc _notendofchain

  ; It's EOC
  lda #$FF
  sta fat32_nextcluster+3
  sec
  rts
_notendofchain:
_runexpand:
  ; Stop if the next FAT entry would come from a different FAT sector.
  lda fat32_runcluster
  and #$7f
  cmp #$7f
  bne :+
  jmp _runexpanddone
:

  ; Stop if the next cluster in the chain is not exactly current+1.
  clc
  lda fat32_runcluster
  adc #1
  php
  cmp fat32_nextcluster
  beq :+
  pla
  jmp _runexpanddone
:
  plp
  lda fat32_runcluster+1
  adc #0
  php
  cmp fat32_nextcluster+1
  beq :+
  pla
  jmp _runexpanddone
:
  plp
  lda fat32_runcluster+2
  adc #0
  php
  cmp fat32_nextcluster+2
  beq :+
  pla
  jmp _runexpanddone
:
  plp
  lda fat32_runcluster+3
  adc #0
  php
  cmp fat32_nextcluster+3
  beq :+
  pla
  jmp _runexpanddone
:
  plp

  ; Stop before pending-sectors overflows its single-byte counter.
  lda fat32_pendingsectors
  clc
  adc fat32_sectorspercluster
  bcc :+
  jmp _runexpanddone
:
  sta fat32_pendingsectors

  ; Advance current cluster to the newly absorbed contiguous cluster.
  lda fat32_nextcluster
  sta fat32_runcluster
  lda fat32_nextcluster+1
  sta fat32_runcluster+1
  lda fat32_nextcluster+2
  sta fat32_runcluster+2
  lda fat32_nextcluster+3
  sta fat32_runcluster+3

  ; Advance to the next FAT entry inside the currently loaded FAT sector.
  tya
  clc
  adc #4
  tay
  bcc :+
  inc zp_sd_address+1
:

  ; Load the next cluster after the expanded run.
  lda (zp_sd_address),y
  sta fat32_nextcluster
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+1
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+2
  iny
  lda (zp_sd_address),y
  and #$0f
  sta fat32_nextcluster+3
  dey
  dey
  dey

  ; If the expanded run reaches EOC, keep the canonical end marker and stop.
  lda fat32_nextcluster+3
  cmp #$0F
  bcs :+
  jmp _runexpand
:
  lda fat32_nextcluster+2
  cmp #$FF
  beq :+
  jmp _runexpand
:
  lda fat32_nextcluster+1
  cmp #$FF
  beq :+
  jmp _runexpand
:
  lda fat32_nextcluster
  cmp #$F8
  bcs :+
  jmp _runexpand
:

  lda #$FF
  sta fat32_nextcluster+3
_runexpanddone:
  clc
  rts


fat32_readnextsector:
  ; Reads the next sector from a cluster chain into the buffer at fat32_address.
  ;
  ; Advances the current sector ready for the next read and looks up the next cluster
  ; in the chain when necessary.
  ;
  ; On return, carry is clear if data was read, or set if the cluster chain has ended.

  ; Maybe there are pending sectors in the current cluster
  lda fat32_pendingsectors
  bne _readsector

  ; No pending sectors, check for end of cluster chain
  lda fat32_nextcluster+3
  cmp #$0F
  bne _not_eoc
  lda fat32_nextcluster+2
  cmp #$FF
  bne _not_eoc
  lda fat32_nextcluster+1
  cmp #$FF
  bne _not_eoc
  lda fat32_nextcluster
  cmp #$F8     ; EOC starts at F8
  bcc _not_eoc

  jmp _readendofchain

_not_eoc:

  ; Prepare to read the next cluster.
  ; Force FAT reload: fat32_readbuffer is also used for data sectors,
  ; so the cached FAT contents may have been overwritten.
  clc
  jsr fat32_seekcluster
  bcc _readsector
  ; A valid final cluster has an EOC link but still contains data.
  lda fat32_pendingsectors
  beq _readendofchain

_readsector:
  dec fat32_pendingsectors

  ; Set up target address
  lda fat32_address
  sta zp_sd_address
  lda fat32_address+1
  sta zp_sd_address+1

  ; Read the sector
  jsr sd_readsector
  bcs _readendofchain

  ; Advance to next sector
  inc zp_sd_currentsector
  bne _sectorincrementdone
  inc zp_sd_currentsector+1
  bne _sectorincrementdone
  inc zp_sd_currentsector+2
  bne _sectorincrementdone
  inc zp_sd_currentsector+3
_sectorincrementdone:

  ; Success - clear carry and return
  clc
  rts

_readendofchain:
  ; End of chain - set carry and return
  sec
  rts

fat32_writenextsector:
  ; Writes the next sector in a cluster chain from the buffer at fat32_address.
  ;
  ; On return, carry is set if its the end of the chain.

  ; Maybe there are pending sectors in the current cluster
  lda fat32_pendingsectors
  bne _beginwrite

  ; No pending sectors, check for end of cluster chain
  lda fat32_nextcluster+3
  bmi _writeendofchain

  ; Prepare to read the next cluster.
  ; Force FAT reload: fat32_readbuffer is also used for data sectors,
  ; so the cached FAT contents may have been overwritten.
  clc
  jsr fat32_seekcluster

_beginwrite:
  jsr _writesector

  ; Success - clear carry and return
  clc
  rts

_writeendofchain:
  ; End of chain - set carry, write a sector, and return
  jsr _writesector
  sec
  rts

_writesector:
  dec fat32_pendingsectors

  ; Set up target address
  lda fat32_address
  sta zp_sd_address
  lda fat32_address+1
  sta zp_sd_address+1

  ; Write the sector
  jsr sd_writesector
  bcs _writeendofchain

  ; Advance to next sector
  inc zp_sd_currentsector
  bne _nextsectorincrementdone
  inc zp_sd_currentsector+1
  bne _nextsectorincrementdone
  inc zp_sd_currentsector+2
  bne _nextsectorincrementdone
  inc zp_sd_currentsector+3
_nextsectorincrementdone:
  rts

fat32_updatefat:
 ; Preserve the current sector
  lda zp_sd_currentsector
  pha
  lda zp_sd_currentsector+1
  pha
  lda zp_sd_currentsector+2
  pha
  lda zp_sd_currentsector+3
  pha

  ; Write FAT sector
  lda fat32_lastsector
  sta zp_sd_currentsector
  lda fat32_lastsector+1
  sta zp_sd_currentsector+1
  lda fat32_lastsector+2
  sta zp_sd_currentsector+2
  lda fat32_lastsector+3
  sta zp_sd_currentsector+3

  ; Target buffer
  lda #<fat32_readbuffer
  sta zp_sd_address
  lda #>fat32_readbuffer
  sta zp_sd_address+1

  ; Write the FAT sector
  jsr sd_writesector
  bcs _fatwrite_fail

  ; Check if FAT mirroring is enabled
  lda fat32_numfats
  cmp #2
  bne _onefat

  ; Add the last sector to the amount of sectors per FAT
  ; (to get the second fat location)
  clc
  lda fat32_lastsector
  adc fat32_sectorsperfat
  sta zp_sd_currentsector
  lda fat32_lastsector+1
  adc fat32_sectorsperfat+1
  sta zp_sd_currentsector+1
  lda fat32_lastsector+2
  adc fat32_sectorsperfat+2
  sta zp_sd_currentsector+2
  lda fat32_lastsector+3
  adc fat32_sectorsperfat+3
  sta zp_sd_currentsector+3

  ; Write the FAT sector
  jsr sd_writesector
  bcs _fatwrite_fail

_onefat:
  ; Pull back the current sector
  pla
  sta zp_sd_currentsector+3
  pla
  sta zp_sd_currentsector+2
  pla
  sta zp_sd_currentsector+1
  pla
  sta zp_sd_currentsector

  clc
  rts

_fatwrite_fail:
  ; Pull back the current sector before returning failure
  pla
  sta zp_sd_currentsector+3
  pla
  sta zp_sd_currentsector+2
  pla
  sta zp_sd_currentsector+1
  pla
  sta zp_sd_currentsector
  sec
  rts

fat32_openroot:
  ; Prepare to read the root directory

  lda #<fat32_readbuffer
  sta fat32_address
  lda #>fat32_readbuffer
  sta fat32_address+1

  lda fat32_rootcluster
  sta fat32_nextcluster
  sta fat32_cdcluster
  lda fat32_rootcluster+1
  sta fat32_nextcluster+1
  sta fat32_cdcluster+1
  lda fat32_rootcluster+2
  sta fat32_nextcluster+2
  sta fat32_cdcluster+2
  lda fat32_rootcluster+3
  sta fat32_nextcluster+3
  sta fat32_cdcluster+3

  clc
  jsr fat32_seekcluster

  ; Force the first directory read to cross the buffer boundary cleanly.
  ; Use readbuffer+$1e0 so the initial +32 lands exactly on readbuffer+$200.
  lda #<(fat32_readbuffer+$1e0)
  sta zp_sd_address
  lda #>(fat32_readbuffer+$1e0)
  sta zp_sd_address+1

  rts

fat32_allocatecluster:
  ; Allocate a cluster to start storing a file at.

  ; Find a free cluster
  jsr fat32_findnextfreecluster
  bcs _fat32_allocatecluster_fail

  ; Cache the value so we can add the address of the next one later, if any
  lda fat32_lastfoundfreecluster
  sta fat32_lastcluster
  sta fat32_filecluster
  lda fat32_lastfoundfreecluster+1
  sta fat32_lastcluster+1
  sta fat32_filecluster+1
  lda fat32_lastfoundfreecluster+2
  sta fat32_lastcluster+2
  sta fat32_filecluster+2
  lda fat32_lastfoundfreecluster+3
  sta fat32_lastcluster+3
  sta fat32_filecluster+3

  ; Add marker for the following routines, so we don't think this is free.
  ; (zp_sd_address),y is controlled by fat32_seekcluster, called in fat32_findnextfreecluster
  ; this points to the most significant byte in the last selected 32-bit FAT entry.
  lda #$0f
  sta (zp_sd_address),y

  clc
  rts

_invalidcluster:
  ; Treat invalid FAT cluster values as end-of-chain.
  lda #$FF
  sta fat32_nextcluster+3
  sec
  rts

_fat32_allocatecluster_fail:
  sec
  rts

fat32_allocatefile:
  ; Allocate an entire file in the FAT, with the
  ; file's size in fat32_bytesremaining

  ; We will read a new sector the first time around
  lda #0
  sta fat32_lastsector
  sta fat32_lastsector+1
  sta fat32_lastsector+2
  sta fat32_lastsector+3

  ; Allocate the first cluster.
  jsr fat32_allocatecluster
  bcc :+
  jmp _fat32_allocatefile_fail_early
:

  ; We don't properly support 64k+ files, as it's unnecessary complication given
  ; the 6502's small address space. So we'll just empty out the top two bytes.
  lda #0
  sta fat32_bytesremaining+2
  sta fat32_bytesremaining+3

  ; Stash filesize, as we will be clobbering it here
  lda fat32_bytesremaining
  pha
  lda fat32_bytesremaining+1
  pha

  ; Round the size up to the next whole sector
  lda fat32_bytesremaining
  cmp #1                      ; set carry if bottom 8 bits not zero
  lda fat32_bytesremaining+1
  adc #0                      ; add carry, if any
  lsr                         ; divide by 2
  adc #0                      ; round up

  ; No data?
  bne _nofail
  jmp _lastclusterdone

_nofail:
  ; This will be clustersremaining now.
  sta fat32_bytesremaining

  ; Divide by sectors per cluster (power of 2)
  ; If it's 1, then skip
  lda fat32_sectorspercluster
_cloop:
  cmp #1
  beq _one

  lsr
  lsr fat32_bytesremaining+1  ; high byte
  ror fat32_bytesremaining    ; low byte, with carry from high

  jmp _cloop

_one:

  ; We will be making a new cluster every time
  lda #0
  sta fat32_pendingsectors

  ; Find free clusters and allocate them for use for this file.
_allocateloop:
  ; We already allocated the first cluster before entering this loop.
  ; If the total cluster count is 0/1, this cluster is the end of chain.
  lda fat32_bytesremaining
  cmp #2
  bcc _lastcluster

  ; More than one cluster total is required, so allocate/link another one.

_notlastcluster:
  ; Find the next cluster
  jsr fat32_findnextfreecluster
  bcc :+
  jmp _fat32_allocatefile_fail_afterpush
:

  ; Add marker so we don't think this is free.
  lda #$0f
  sta (zp_sd_address),y

  ; Seek to the previous cluster
  lda fat32_lastcluster
  sta fat32_nextcluster
  lda fat32_lastcluster+1
  sta fat32_nextcluster+1
  lda fat32_lastcluster+2
  sta fat32_nextcluster+2
  lda fat32_lastcluster+3
  sta fat32_nextcluster+3

  sec
  jsr fat32_seekcluster

  tya
  pha
  ; Enter the address of the next one into the FAT in little-endian order.
  lda fat32_lastfoundfreecluster
  sta fat32_lastcluster
  sta (zp_sd_address),y
  iny
  lda fat32_lastfoundfreecluster+1
  sta fat32_lastcluster+1
  sta (zp_sd_address),y
  iny
  lda fat32_lastfoundfreecluster+2
  sta fat32_lastcluster+2
  sta (zp_sd_address),y
  iny
  lda fat32_lastfoundfreecluster+3
  and #$0f
  sta fat32_lastcluster+3
  sta (zp_sd_address),y
  pla
  tay

  ; Update the FAT
  jsr fat32_updatefat

  ldx fat32_bytesremaining    ; note - actually loads clusters remaining
  dex
  stx fat32_bytesremaining    ; note - actually stores clusters remaining

  bne _allocateloop

  ; Done!

_lastcluster:

; go back the previous one
  lda fat32_lastcluster
  sta fat32_nextcluster
  lda fat32_lastcluster+1
  sta fat32_nextcluster+1
  lda fat32_lastcluster+2
  sta fat32_nextcluster+2
  lda fat32_lastcluster+3
  sta fat32_nextcluster+3

  sec
  jsr fat32_seekcluster

  ; Write 0x0FFFFFFE (EOC) in little-endian FAT order.
  lda #$fe
  sta (zp_sd_address),y
  iny
  lda #$ff
  sta (zp_sd_address),y
  iny
  sta (zp_sd_address),y
  iny
  lda #$0f
  sta (zp_sd_address),y

  ; Update the FAT
  jsr fat32_updatefat

  ; End of chain - exit
_lastclusterdone:
  ; Pull the filesize back from the stack
  pla
  sta fat32_bytesremaining+1
  pla
  sta fat32_bytesremaining
  clc
  rts

_fat32_allocatefile_fail_afterpush:
  ; Restore original byte count before returning failure.
  pla
  sta fat32_bytesremaining+1
  pla
  sta fat32_bytesremaining
  sec
  rts

_fat32_allocatefile_fail_early:
  sec
  rts


fat32_findnextfreecluster:
; Find next free cluster
;
; This program will search the FAT for an empty entry, and
; save the 32-bit cluster number at fat32_lastfoundfreecluter.
;
; Also sets the carry bit if the SD card is full.
;

  ; Find a free cluster and store it's location in fat32_lastfoundfreecluster

  ; Cluster ids 0 and 1 are reserved on FAT32. Start searching at 2.
  lda #2
  sta fat32_nextcluster
  sta fat32_lastfoundfreecluster
  lda #0
  sta fat32_nextcluster+1
  sta fat32_lastfoundfreecluster+1
  sta fat32_nextcluster+2
  sta fat32_lastfoundfreecluster+2
  sta fat32_nextcluster+3
  sta fat32_lastfoundfreecluster+3

_searchclusters:

  ; Seek cluster
  sec
  jsr fat32_seekcluster

  ; Is the cluster free?
  lda fat32_nextcluster
  ora fat32_nextcluster+1
  ora fat32_nextcluster+2
  ora fat32_nextcluster+3
  beq _foundcluster

  ; No, increment the cluster count
  inc fat32_lastfoundfreecluster
  bne _copycluster
  inc fat32_lastfoundfreecluster+1
  bne _copycluster
  inc fat32_lastfoundfreecluster+2
  bne _copycluster
  inc fat32_lastfoundfreecluster+3

  ; FAT32 cluster numbers are 28-bit. If the high nibble overflows,
  ; we've exhausted the searchable range.
  lda fat32_lastfoundfreecluster+3
  and #$f0
  bne _sd_full

_copycluster:

  ; Copy the cluster count to the next cluster
  lda fat32_lastfoundfreecluster
  sta fat32_nextcluster
  lda fat32_lastfoundfreecluster+1
  sta fat32_nextcluster+1
  lda fat32_lastfoundfreecluster+2
  sta fat32_nextcluster+2
  lda fat32_lastfoundfreecluster+3
  and #$0f
  sta fat32_nextcluster+3

  ; Go again for another pass
  jmp _searchclusters

_foundcluster:
  ; done.
  clc
  rts

_sd_full:
  ; Card Full
  sec
  rts

fat32_opendirent:
  ; Prepare to read/write a file or directory based on a dirent
  ;
  ; Point zp_sd_address at the dirent

  ; Remember file size in bytes remaining
  ldy #28
  lda (zp_sd_address),y
  sta fat32_bytesremaining
  iny
  lda (zp_sd_address),y
  sta fat32_bytesremaining+1
  iny
  lda (zp_sd_address),y
  sta fat32_bytesremaining+2
  iny
  lda (zp_sd_address),y
  sta fat32_bytesremaining+3

  ; Seek to first cluster
  ldy #26
  lda (zp_sd_address),y
  sta fat32_nextcluster
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+1
  ldy #20
  lda (zp_sd_address),y
  sta fat32_nextcluster+2
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+3

  clc
  ldy #$0B
  lda (zp_sd_address),Y
  and #$10   ; is it a directory?
  beq _fatskip_cd_cache

  ; If it's a directory, cache the cluster
  lda fat32_nextcluster
  sta fat32_cdcluster
  lda fat32_nextcluster+1
  sta fat32_cdcluster+1
  lda fat32_nextcluster+2
  sta fat32_cdcluster+2
  lda fat32_nextcluster+3
  sta fat32_cdcluster+3

_fatskip_cd_cache:

  ; if we're opening a directory entry with 0 cluster, use the root cluster
  lda fat32_nextcluster+3
  bne _fseek
  lda fat32_nextcluster+2
  bne _fseek
  lda fat32_nextcluster+1
  bne _fseek
  lda fat32_nextcluster
  bne _fseek
  lda fat32_rootcluster
  sta fat32_nextcluster
  sta fat32_cdcluster

_fseek:
  clc
  jsr fat32_seekcluster

  ; Force the first file sector read to cross the buffer boundary cleanly.
  lda #<(fat32_readbuffer+$1e0)
  sta zp_sd_address
  lda #>(fat32_readbuffer+$1e0)
  sta zp_sd_address+1

  rts

fat32_writedirent:
  ; Write a directory entry from the open directory
  ; requires:
  ;   fat32bytesremaining (2 bytes) = file size in bytes (little endian)

  ; Increment pointer by 32 to point to next entry
  clc
  lda zp_sd_address
  adc #32
  sta zp_sd_address
  lda zp_sd_address+1
  adc #0
  sta zp_sd_address+1

  ; If it's not at the end of the buffer, we have data already
  cmp #>(fat32_readbuffer+$200)
  bcc _gotdirrent

  ; Read another sector
  lda #<fat32_readbuffer
  sta fat32_address
  lda #>fat32_readbuffer
  sta fat32_address+1

  jsr fat32_readnextsector
  bcc _gotdirrent

_endofdirectorywrite:
  sec
  rts

_gotdirrent:
  ; Check first character
  clc
  ldy #0
  lda (zp_sd_address),y
  beq _dnewentry        ; end of directory
  cmp #$e5
  bne fat32_writedirent ; in use - go again
  ; A deleted entry: reuse it, so deleting and re-creating files (as
  ; level and save files are) does not grow the directory without limit.
_dnewentry:
  ; Now make a new entry.
_dloop:
  lda (fat32_filenamepointer),y  ; copy filename
  sta (zp_sd_address),y
  iny
  cpy #$0b
  bne _dloop
  ; The full Short filename is #11 bytes long so,
  ; this start at 0x0b - File type
  ; BUG assumes that we are making a file, not a folder...
  lda #$20    ; File Type: ARCHIVE
  sta (zp_sd_address),y
  iny   ; 0x0c - Checksum/File accsess password
  lda #$10                ; No checksum or password
  sta (zp_sd_address),y
  iny   ; 0x0d - first char of deleted file - 0x7d for nothing
  lda #$7D
  sta (zp_sd_address),y
  iny  ; 0x0e-0x11 - File creation time/date
  lda #0
_empty:
  sta (zp_sd_address),y	; No time/date because I don't have an RTC
  iny
  cpy #$14 ; also empty the user ID (0x12-0x13)
  bne _empty
  ;sta (zp_sd_address),y
  ;iny
  ;sta (zp_sd_address),y
  ;iny
  ;sta (zp_sd_address),y
  ; if you have an RTC, refer to https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system#Directory_entry
  ; show the "Directory entry" table and look at at 0x0E onward.
  ;iny   ; 0x12-0x13 - User ID
  ;lda #0
  ;sta (zp_sd_address),y  ; No ID
  ;iny
  ;sta (zp_sd_address),y
  ;iny
  ; 0x14-0x15 - File start cluster (high word)
  lda fat32_filecluster+2
  sta (zp_sd_address),y
  iny
  lda fat32_filecluster+3
  sta (zp_sd_address),y
  iny ; 0x16-0x19 - File modifiaction date
  lda #0
  sta (zp_sd_address),y
  iny
  sta (zp_sd_address),y   ; no rtc
  iny
  sta (zp_sd_address),y
  iny
  sta (zp_sd_address),y
  iny ; 0x1a-0x1b - File start cluster (low word)
  lda fat32_filecluster
  sta (zp_sd_address),y
  iny
  lda fat32_filecluster+1
  sta (zp_sd_address),y
  iny ; 0x1c-0x1f File size in bytes
  lda fat32_bytesremaining
  sta (zp_sd_address),y
  iny
  lda fat32_bytesremaining+1
  sta (zp_sd_address),y
  iny
  lda #0
  sta (zp_sd_address),y ; No bigger that 64k
  iny
  sta (zp_sd_address),y
  iny
  ; are we over the buffer?
  lda zp_sd_address+1
  cmp #>(fat32_readbuffer+$200)
  bcc _notoverbuffer
  jsr fat32_writecurrentsector       ; if so, write the current sector
  jsr fat32_readnextsector  ; then read the next one.
  bcs _dfail
  ldy #0
  lda #<fat32_readbuffer
  sta zp_sd_address
  lda #>fat32_readbuffer
  sta zp_sd_address+1
_notoverbuffer:
  ; next entry is 0 (end of dir)
  lda #0
  sta (zp_sd_address),y
  ; Write the dirent.
  jsr fat32_writecurrentsector

  ; Great, lets get this ready for other code to read in.

  ; Seek to first cluster
  lda fat32_filecluster
  sta fat32_nextcluster
  lda fat32_filecluster+1
  sta fat32_nextcluster+1
  lda fat32_filecluster+2
  sta fat32_nextcluster+2
  lda fat32_filecluster+3
  sta fat32_nextcluster+3

  clc
  jsr fat32_seekcluster

  ; Set the pointer to a large value so we always read a sector the first time through
  lda #$ff
  sta zp_sd_address+1

  clc
  rts

_dfail:
  ; Card Full
  sec
  rts

fat32_writecurrentsector:

  ; decrement the sector so we write the current one (not the next one)
  lda zp_sd_currentsector
  bne _skip
  dec zp_sd_currentsector+1
  bne _skip
  dec zp_sd_currentsector+2
  bne _skip
  dec zp_sd_currentsector+3

_skip:
  dec zp_sd_currentsector

_nodec:

  lda fat32_address
  sta zp_sd_address
  lda fat32_address+1
  sta zp_sd_address+1

  ; Read the sector
  jsr sd_writesector

  ; Advance to next sector
  inc zp_sd_currentsector
  bne _writesectorincrementdone
  inc zp_sd_currentsector+1
  bne _writesectorincrementdone
  inc zp_sd_currentsector+2
  bne _writesectorincrementdone
  inc zp_sd_currentsector+3

_writesectorincrementdone:
  rts

fat32_readdirent:
  ; Read a directory entry from the open directory
  ;
  ; On exit the carry is set if there were no more directory entries.
  ;
  ; Otherwise, A is set to the file's attribute byte and
  ; zp_sd_address points at the returned directory entry.
  ; LFNs and empty entries are ignored automatically.

_scan_next_entry:
  ; Increment pointer by 32 to point to next entry
  clc
  lda zp_sd_address
  adc #32
  sta zp_sd_address
  lda zp_sd_address+1
  adc #0
  sta zp_sd_address+1

  ; If it's not at the end of the buffer, we have data already
  cmp #>(fat32_readbuffer+$200)
  bcc _gotdirdata

  ; Read another sector
  lda #<fat32_readbuffer
  sta fat32_address
  lda #>fat32_readbuffer
  sta fat32_address+1

  jsr fat32_readnextsector
  bcc _gotdirdata
_endofdirectory:
  sec
  rts

_gotdirdata:
  ; Check first character
  ldy #0
  lda (zp_sd_address),y

  ; End of directory => abort
  beq _endofdirectory

  ; Empty entry => keep scanning
  cmp #$e5
  bne :+
  jmp _scan_next_entry
:

  ; Check attributes
  ldy #11
  lda (zp_sd_address),y
  and #$3f
  cmp #$0f ; LFN => keep scanning
  bne :+
  jmp _scan_next_entry
:

  ; Yield this result
  clc
  rts


fat32_finddirent:
  ; Finds a particular directory entry. X,Y point to the 11-character filename to seek.
  ; The directory should already be open for iteration.

  ; Form ZP pointer to user's filename
  stx fat32_filenamepointer
  sty fat32_filenamepointer+1

  ; Iterate until name is found or end of directory
_direntloop:
  jsr fat32_readdirent
  ldy #10
  bcc _comparenameloop
  rts ; with carry set

_comparenameloop:
  lda (zp_sd_address),y
  cmp (fat32_filenamepointer),y
  bne _direntloop ; no match
  dey
  bpl _comparenameloop

  ; Found it
  clc
  rts

fat32_markdeleted:
  ; Mark the file as deleted
  ; We need to stash the first character at index 0x0D
  ldy #$00
  lda (zp_sd_address),y
  ldy #$0d
  sta (zp_sd_address),y

  ; Now put 0xE5 at the first byte
  ldy #$00
  lda #$e5
  sta (zp_sd_address),y

  ; Get start cluster high word
  ldy #$14
  lda (zp_sd_address),y
  sta fat32_nextcluster+2
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+3

  ; And low word
  ldy #$1a
  lda (zp_sd_address),y
  sta fat32_nextcluster
  iny
  lda (zp_sd_address),y
  sta fat32_nextcluster+1

  ; Write the dirent
  jsr fat32_writecurrentsector

  ; Done
  clc
  rts

fat32_deletefile:
  ; Removes the open file from the SD card.
  ; The directory needs to be open and
  ; zp_sd_address pointed to the first byte of the file entry.

  ; Mark the file as "Removed"
  jsr fat32_markdeleted

  ; We will read a new sector the first time around
  lda #$00
  sta fat32_lastsector
  sta fat32_lastsector+1
  sta fat32_lastsector+2
  sta fat32_lastsector+3

  ; Now we need to iterate through this file's cluster chain, and remove it from the FAT.
  ldy #0
_chainloop:
  ; Seek to cluster
  sec
  jsr fat32_seekcluster

  ; Is this the end of the chain?
  lda fat32_nextcluster+3
  bmi _deletefileendofchain

  ; Zero it out
  lda #0
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y

  ; Write the FAT
  jsr fat32_updatefat

  ; And go again for another pass.
  jmp _chainloop

_deletefileendofchain:
  ; This is the last cluster in the chain.

  ; Just zero it out,
  lda #0
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y
  dey
  sta (zp_sd_address),y

  ; Write the FAT
  jsr fat32_updatefat

  ; And we're done!
  clc
  rts

fat32_file_readbyte:
  ; Read a byte from an open file
  ;
  ; The byte is returned in A with C clear; or if end-of-file was reached, C is set instead

  ; Is there any data to read at all?
  lda fat32_bytesremaining
  ora fat32_bytesremaining+1
  ora fat32_bytesremaining+2
  ora fat32_bytesremaining+3
  beq _fat32_file_readbyte_eof

  ; Decrement the remaining byte count (faster carry-chain than 4x SBC).
  dec fat32_bytesremaining
  lda fat32_bytesremaining
  cmp #$FF
  bne :+
  dec fat32_bytesremaining+1
  lda fat32_bytesremaining+1
  cmp #$FF
  bne :+
  dec fat32_bytesremaining+2
  lda fat32_bytesremaining+2
  cmp #$FF
  bne :+
  dec fat32_bytesremaining+3
:

  ; Need to read a new sector?
  lda zp_sd_address+1
  cmp #>(fat32_readbuffer+$200)
  bcc _gotdata

  ; Read another sector
  lda #<fat32_readbuffer
  sta fat32_address
  lda #>fat32_readbuffer
  sta fat32_address+1

  jsr fat32_readnextsector
  bcs _fat32_file_readbyte_eof

_gotdata:
  ldy #0
  lda (zp_sd_address),y

  inc zp_sd_address
  bne _fat32_file_readbyte_ok
  inc zp_sd_address+1

_fat32_file_readbyte_ok:
  clc
  rts

_fat32_file_readbyte_eof:
  sec
  rts


fat32_file_read:
  ; Read a whole file into memory.  It's assumed the file has just been opened
  ; and no data has been read yet.
  ;
  ; Also we read whole sectors, so data in the target region beyond the end of the
  ; file may get overwritten, up to the next 512-byte boundary.
  ;
  ; And we don't properly support 64k+ files, as it's unnecessary complication given
  ; the 6502's small address space

  ; Round the size up to the next whole sector
  lda fat32_bytesremaining
  cmp #1                      ; set carry if bottom 8 bits not zero
  lda fat32_bytesremaining+1
  adc #0                      ; add carry, if any
  lsr                         ; divide by 2
  adc #0                      ; round up

  ; No data?
  beq _fat32_file_read_done

  ; Store sector count - not a byte count any more
  sta fat32_bytesremaining

  ; Read entire sectors to the user-supplied buffer
_wholesectorreadloop:
  ; Read a sector to fat32_address
  jsr fat32_readnextsector

  ; Advance fat32_address by 512 bytes
  lda fat32_address+1
  adc #2                      ; carry already clear
  sta fat32_address+1

  ldx fat32_bytesremaining    ; note - actually loads sectors remaining
  dex
  stx fat32_bytesremaining    ; note - actually stores sectors remaining

  bne _wholesectorreadloop

_fat32_file_read_done:
  rts

fat32_file_write:
  ; Write a whole file from memory.  It's assumed the dirent has just been created
  ; and no data has been written yet.

  ; Start at the first cluster for this file
  lda fat32_filecluster
  sta fat32_lastcluster
  lda fat32_filecluster+1
  sta fat32_lastcluster+1
  lda fat32_filecluster+2
  sta fat32_lastcluster+2
  lda fat32_filecluster+3
  sta fat32_lastcluster+3

  lda fat32_filecluster
  sta fat32_nextcluster
  lda fat32_filecluster+1
  sta fat32_nextcluster+1
  lda fat32_filecluster+2
  sta fat32_nextcluster+2
  lda fat32_filecluster+3
  sta fat32_nextcluster+3

  ; Round the size up to the next whole sector
  lda fat32_bytesremaining
  cmp #1                      ; set carry if bottom 8 bits not zero
  lda fat32_bytesremaining+1
  adc #0                      ; add carry, if any
  lsr                         ; divide by 2
  adc #0                      ; round up

  ; No data?
  beq _fat32_file_write_done

  ; Store sector count - not a byte count anymore.
  sta fat32_bytesremaining

  ; We will be making a new cluster the first time around
  lda #$00
  sta fat32_pendingsectors

  ; Write entire sectors from the user-supplied buffer
_wholesectorwriteloop:
  ; Write a sector from fat32_address
  jsr fat32_writenextsector
  ;bcs _fail  ; this shouldn't happen

  ; Advance fat32_address by 512 bytes
  clc
  lda fat32_address+1
  adc #2
  sta fat32_address+1

  ldx fat32_bytesremaining    ; note - actually loads sectors remaining
  dex
  stx fat32_bytesremaining    ; note - actually stores sectors remaining

  bne _wholesectorwriteloop

  ; Done!
_fat32_file_write_done:
  rts

fat32_open_cd:
  ; Prepare to read from the current (last opened) directory.

  pha
  txa
  pha
  tya
  pha

  ; Seek to first cluster of current directory
  lda fat32_cdcluster
  sta fat32_nextcluster
  lda fat32_cdcluster+1
  sta fat32_nextcluster+1
  lda fat32_cdcluster+2
  sta fat32_nextcluster+2
  lda fat32_cdcluster+3
  sta fat32_nextcluster+3

  lda #<fat32_readbuffer
  sta fat32_address
  lda #>fat32_readbuffer
  sta fat32_address+1

  clc
  jsr fat32_seekcluster

  ; Set the pointer to a large value so we always read a sector the first time through
  lda #$ff
  sta zp_sd_address+1

  pla
  tay
  pla
  tax
  pla
  rts
