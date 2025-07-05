#! python3

# Get the libraries we need for OS handling
import os, sys

# Get the PDF libararies (needs to be installed first with `pip3 install PyPDF2`)
import PyPDF2
from PyPDF2 import PdfFileMerger

# Input path from the first argument passed to the command line. Index 0 is the script itself so need to start at 1
inputPath = sys.argv[1]

# Output path is the second argument passed to the script,index 2. 
outputPath = sys.argv[2]

# Get all the PDF filenames in the path from the CLI arguments.
pdfFiles = []
for filename in os.listdir(inputPath):
	if filename.endswith('.pdf'):
		pdfFiles.append(inputPath + '/' + filename)
# Sort the PDFs then reverse the sort. The output prepends the date and we want the newest files at the top of the merged PDF.
pdfFiles.sort()
pdfFiles.reverse()

# Loop through all the PDF files.
merger = PdfFileMerger()

# Merging them
for pdf in pdfFiles:
    merger.append(pdf)

# Write the file to the path from above and name it. 
merger.write(outputPath)
merger.close()