#!/bin/bash
# Mock sendmail script for testing
# Accepts standard sendmail parameters and displays the email content

# Parse arguments (we accept -t -i but don't need to do anything with them)
while getopts "tif:" opt; do
  case $opt in
    t|i|f)
      # Standard sendmail options, just ignore them
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Read the email from stdin and display it
echo "=========================================="
echo "Mock Sendmail - Email Content:"
echo "=========================================="
cat
echo ""
echo "=========================================="
echo "Email would be sent via sendmail"
echo "=========================================="

exit 0
