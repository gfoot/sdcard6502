# How to read SD cards with a 6502, step by step

   (image)

This guide shows how to connect up an SD card reader to a Ben Eater style 6502
homebrew computer and use it to read data from SDHC cards.

The tutorial ends with being able to read arbitrary sectors from the SDHC card.
The next step beyond that is to support a filesystem.  I do have 6502 code to
read exfat volumes which I'll add here soon, but it needs adapting to work on
top of the specific code I wrote for this tutorial, as it's not the same as the
code I use day-to-day.  So for now we end after reading a sector and printing
some data from it.

I'm also only covering SDHC cards.  You pretty much can't buy older/smaller
cards these days, and not bothering to support the older protocol simplifies
the code quite a bit.

# Contents

### Intro
* [0a Prerequisites and References](0a_Prereqs.md)
* [0b About the Sample Code](0b_SampleCode.md)
* [0c Initial Hardware Setup](0c_HardwareSetup.md)

### Samples
* [1  Reading and Writing Bytes](1_ReadingWritingBytes.md)
* [2  Encaplusated sd\_sendcommand](2_SendCommand.md)
* [3  Complete Initialization Sequence](3_Initialization.md)
* [4  Reading Sectors](4_ReadingSectors.md)
  
### Appendices
* [A  Next Steps](A_NextSteps.md)
* [B  Older SD/MMC Cards](B_OlderCards.md)

