#!/usr/bin/perl

# N.B. 0 arguments, read stdin, write stdout.
# 1 argument, read ARGV[0], write stdout.
# 2 arguments, read ARGV[1], write ARGV[2].
if (@ARGV > 1) {
    open (my $output, '>', $ARGV[1]);
    select $output;
}

# Endianness is a parameter to the (non-block-compressed) generators
# This doesn't have to be a number: $bigEndian = "myBigEndianFlag" will drop this argument in the generated code
$bigEndian = 0;

# Keep track of formats we've seen to avoid duplicates
%foundFormats = ();

# Loop over each line of input
while ($line = <>) {

    # Match any format that starts with a channel description (some number of R, G, B, A or a number)
    # In PERL, "=~" performs a regex operation on the left argument
    # m/<regex>/ matches the regular expression
    if ($line =~ m/VK_FORMAT_[RGBA0-9]+_/) {

        # Set $format to the enum identifier
        ($line =~ m/(VK_FORMAT[A-Z0-9_]+)/);

        # $<number> holds the <number>'th parenthesised entry in the previous regex
        # (only one in this case)
        $format = $1;

        # Skip a format if we've already processed it
        if (!exists($foundFormats{$format})) {

            # Packed formats end "_PACK<n>" - is this format packed?
            if ($format =~ m/_PACK/) {

                # Extract the channel identifiers and suffix from the packed format
                $format =~ m/VK_FORMAT_([RGBA0-9]+)_([^_]+)_PACK[0-9]+/;

                # The first parenthesised bit of regex is the channels ("R5G5B5" etc.)
                $channels = $1;

                # The second parenthesised bit of regex is the suffix ("UNORM" etc.)
                $suffix = $2;

                # N.B. We don't care about the total bit count (after "PACK" in the name)

                # Create an empty array of channel names and corresponding bits
                @packChannels = ();
                @packBits = ();

                # Loop over channels, separating out the last letter followed by a number
                while ($channels =~ m/([RGBA0-9]*)([RGBA])([0-9]+)/) {

                    # Add the rightmost channel name to our array
                    push @packChannels, $2;

                    # Add the rightmost channel bits to the array
                    push @packBits, $3;

                    # Truncate the channels string to remove the channel we've processed
                    $channels = $1;
                }

                # The number of channels we've found is the array length we've built
                $numChannels = @packChannels;

                # Packed output needs a C block for local variables
                print "case $format: {\n";

                # Start with a null list of channel ids
                $channelIds = "";

                # Loop over the channel names we've found
                foreach (@packChannels) {

                    # Use a comma as a separator, so don't add it if the $channelIds string is empty
                    if ($channelIds ne "") { $channelIds .= ","; }

                    # Map the channel names to our internal numbering
                    if ($_ eq 'R') { $channelIds .= "0"; }
                    elsif ($_ eq 'G') { $channelIds .= "1"; }
                    elsif ($_ eq 'B') { $channelIds .= "2"; }
                    elsif ($_ eq 'A') { $channelIds .= "3"; }
                }

                # Channel bit counts are easier: we can use join() to make a comma-separated
                # string of the numbers in the array
                $channelBits = join (',', @packBits);

                # Print initialisation for the two arrays we've created
                print "    int channels[] = {" . $channelIds . "}; ";
                print "int bits[] = {" . $channelBits . "};\n";

                # Now print the function call and close the block
                print "    return createDFDPacked($bigEndian, $numChannels, bits, channels, s_$suffix);\n";
                print "}\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # If we're not packed, do we have a simple RGBA channel size list with a suffix?
                # N.B. We don't want to pick up downsampled or planar formats, which have more _-separated fields
                # - "$" matches the end of the format identifier
            } elsif ($format =~ m/VK_FORMAT_([RGBA0-9]+)_([^_]+)$/) {

                # Extract our "channels" (e.g. "B8G8R8") and "suffix" (e.g. "UNORM")
                $channels = $1;
                $suffix = $2;

                # Non-packed format either start with red (R8G8B8A8) or blue (B8G8R8A8)
                # We have a special case to notice when we start with blue
                if (substr($channels,0,1) eq "B") {

                    # Red and blue are swapped (B, G, R, A) - record this
                    # N.B. createDFDUnpacked() just knows this and R,G,B,A channel order, not arbitrary
                    $rbswap = 1;

                    # We know we saw "B" for blue, so we must also have red and green
                    $numChannels = 3;

                    # If we have "A" in the channels as well, we have four channels
                    if ($channels =~ m/A/) {
                        $numChannels = 4;
                    }
                } else {

                    # We didn't start "B", so we're in conventional order (R, G, B, A)
                    $rbswap = 0;

                    # Check for the channel names present and map that to the number of channels
                    if ($channels =~ m/A/) {
                        $numChannels = 4;
                    } elsif ($channels =~ m/B/) {
                        $numChannels = 3;
                    } elsif ($channels =~ m/G/) {
                        $numChannels = 2;
                    } else {
                        $numChannels = 1;
                    }
                }

                # In an unpacked format, all the channels are the same size, so we only need to check one
                $channels =~ m/R([0-9]+)/;

                # For unpacked, we need bytes per channel, not bits
                $bytesPerChannel = $1 / 8;

                # Output the case entry
                print "case $format: return createDFDUnpacked($bigEndian, $numChannels, $bytesPerChannel, $rbswap, s_$suffix);\n";
                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;
            }
        }

    # If we weren't VK_FORMAT_ plus a channel, we might be a compressed format, that ends "_BLOCK"
    } elsif ($line =~ m/(VK_FORMAT_[A-Z0-9x_]+_BLOCK)/) {

        # Extract the format identifier from the rest of the line
        $format = $1;

        # Skip a format if we've already processed it
        if (!exists($foundFormats{$format})) {

            # Special-case BC1_RGB to separate it from BC1_RGBA
            if ($line =~ m/VK_FORMAT_BC1_RGB_([A-Z]+)_BLOCK/) {

                # Pull out the suffix ("UNORM" etc.)
                $suffix = $1;

                # Output the special case - a 4x4 BC1 block
                print "case $format: return createDFDCompressed(c_BC1_RGB, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # Special case BC1_RGBA (but still extract the suffix with a regex)
            } elsif ($line =~ m/VK_FORMAT_BC1_RGBA_([A-Z]+)_BLOCK/) {
                $suffix = $1;
                print "case $format: return createDFDCompressed(c_BC1_RGBA, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # All the other BC formats don't have a channel identifier in the name, so we regex match them
            } elsif ($line =~ m/VK_FORMAT_(BC[2-7H])_([A-Z]+)_BLOCK/) {
                $scheme = $1;
                $suffix = $2;
                print "case $format: return createDFDCompressed(c_$scheme, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # The ETC and EAC formats have two-part names (ETC2_R8G8B8, EAC_R11 etc.) starting with "E"
            } elsif ($line =~ m/VK_FORMAT_(E[^_]+_[^_]+)_([A-Z]+)_BLOCK/) {
                $scheme = $1;
                $suffix = $2;
                print "case $format: return createDFDCompressed(c_$scheme, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # Finally, ASTC, the only case where the block size is a parameter
            } elsif ($line =~ m/VK_FORMAT_ASTC_([0-9]+)x([0-9]+)_([A-Z]+)_BLOCK/) {
                $w = $1;
                $h = $2;
                $suffix = $3;
                print "case $format: return createDFDCompressed(c_ASTC, $w, $h, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;
            }

            # Currently PVRTC drops through unmatched, pending support
        }
    }

    # ...and continue to the next line
}
