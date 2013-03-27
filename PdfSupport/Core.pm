# Copyright 2013, mm1352000

# This file is part of NzSatEpg.

# NzSatEpg is free software: you can redistribute it and/or modify it under the
# terms of the GNU Affero Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.

# NzSatEpg is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero Public License for more details.

# You should have received a copy of the GNU Affero Public License along with
# NzSatEpg. If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

package PdfSupport::Core;

use PDF::API2;
use PDF::API2::Util qw(uniByName unfilter);
use PDF::API2::Resource::BaseFont;
use Storable qw(dclone);

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(open getPageCount setTextHandler setPathHandler setDebugStream readPage structure close);
use PdfSupport::Font::KnownEncodings qw(getRawEncoding);


# "Static" Common Variables
my %predefEncodingMap;            # Holds predefined (PDF core) encoding maps. They are added as required.


sub open {

    my ($class, $pdf, $textHandler, $pathHandler, $debugStream) = @_;
    return undef if (!(-f $pdf));

    my $self = {};
    bless($self, $class);
    $self->{'doc'} = PDF::API2->open($pdf);
    return undef if (!defined $self->{'doc'});

    # Make sure the debug stream is initialised.
    if (!defined $debugStream) {
        my $nullStream = ($^O =~ m/MSWin/) ? 'NUL' : '/dev/null';
        open($debugStream, ">$nullStream");
    }
    $self->{'debugStream'} = $debugStream;

    # Make sure the text and path handlers are set.
    $self->{'textHandler'} = $self->setTextHandler($textHandler);
    $self->{'pathHandler'} = $self->setPathHandler($pathHandler);

    return $self;
}

sub getPageCount {

    my ($self) = @_;
    return $self->{'doc'}->pages();
}

sub readPage {

    my ($self, $pageNum, $dumpRawStream, $logicalStringSeparation) = @_;

    # Release memory from any previous pages.
    print { $self->{'debugStream'} } "PdfSupport::Core: Reading PDF page number $pageNum...\n";
    $self->releasePageMemory();

    # Get the page stream for the page that the user wants to process.
    $self->{'pageVars'}{'pageObj'} = $self->{'doc'}->openpage($pageNum);
    return if (!defined $self->{'pageVars'}{'pageObj'});       # Make sure the page exists!
    my $pageContent = $self->{'pageVars'}{'pageObj'}{'Contents'}->val->[0];
    $self->{'pageVars'}{'pageNumber'} = $pageNum;
    $self->{'pageVars'}{'fullStream'} = $pageContent->{' stream'};
    if (!$pageContent->{' unfilt'}) {
        $self->{'pageVars'}{'fullStream'} = unfilter($pageContent->{'Filter'}, $self->{'pageVars'}{'fullStream'});
    }
    $self->{'pageVars'}{'stream'} = $self->{'pageVars'}{'fullStream'};

    # Dump the raw page stream if we've been asked to do that.
    if (defined $dumpRawStream && $dumpRawStream) {
        print { $self->{'debugStream'} } "\nPdfSupport::Core: ===============\n";
        print { $self->{'debugStream'} } "PdfSupport::Core: RAW PAGE STREAM\n";
        print { $self->{'debugStream'} } "PdfSupport::Core: ===============\n";
        print { $self->{'debugStream'} } $self->{'pageVars'}{'fullStream'} . "\n\n\n";
    }

    # The logical string separation is the minimum inter-character adjustment that we recognise as
    # being a separator for two logical strings. For some applications this is critical; for others
    # this is not so relevant.
    if (defined $logicalStringSeparation) {
        $self->{'logicalStringSeparation'} = abs($logicalStringSeparation);
    }
    else {
        $self->{'logicalStringSeparation'} = 200;
    }
    print { $self->{'debugStream'} } 'PdfSupport::Core: logical string separation = ' . $self->{'logicalStringSeparation'} . "\n";

    # Set initial values for graphics state parameters.
    $self->{'graphicsState'} = {
        'lineWidth'             => 1
        , 'lineCap'             => 0    # (square butt caps)
        , 'lineJoin'            => 0    # (mitred joins)
        , 'mitreLimit'          => 10
        , 'dashArray'           => []   # (solid line)
        , 'dashPhase'           => 0
        , 'renderingIntent'     => 'RelativeColorimetric'
        , 'strokeAdjustment'    => 0
        , 'blendMode'           => 'Normal'
        , 'softMask'            => 'None'
        , 'alphaSource'         => 0
        , 'overprintMode'       => 0
        , 'blackGeneration'     => undef
        , 'undercolourRemoval'  => undef
        , 'transferFunction'    => undef
        , 'halftoneScreen'      => undef
        , 'flatnessTolerance'   => 0
        , 'smoothnessTolerance' => 0.5
    };
    $self->{'graphicsState'}{'CTM'} = [1, 0, 0, 1, 0, 0];
    $self->{'graphicsState'}{'clippingPath'} = [];
    $self->{'graphicsState'}{'stroking'} = {
        'colourSpace'       => 'DeviceGray'
        , 'colour'          => [0]      # black
        , 'alphaConstant'   => 1
        , 'overprint'       => 0
    };
    $self->{'graphicsState'}{'nonstroking'} = {
        'colourSpace'       => 'DeviceGray'
        , 'colour'          => [0]      # black
        , 'alphaConstant'   => 1
        , 'overprint'       => 0
    };
    $self->{'graphicsState'}{'text'} = {
        'characterSpacing'      => 0
        , 'wordSpacing'         => 0
        , 'horizontalScaling'   => 1
        , 'leading'             => 0
        , 'fontName'            => undef
        , 'fontSize'            => undef
        , 'renderMode'          => 0
        , 'rise'                => 0
        , 'knockout'            => 1
    };
    $self->{'graphicsStateStack'} = [];
    $self->{'pageVars'}{'opStack'} = [];

    $self->buildFontMap();
    $self->processPageStream();
}

sub processPageStream {

    my ($self) = @_;
    print { $self->{'debugStream'} } "PdfSupport::Core: Processing page stream...\n";

    my $inTextObject = 0;
    my $inPathObject = 0;
    my $inClippingPathObject = 0;
    my $painting = 0;
    my $op;
    $self->{'pageVars'}{'stream'} =~ s/\A\s*([^\s].*[^\s])\s*\z/$1/s;
    while ($self->{'pageVars'}{'stream'}) {
        # Numeric operand...
        if ($self->{'pageVars'}{'stream'} =~ m/\A(-?\d+(\.\d+)?)\s+([^\s].*)/s) {
            $self->{'pageVars'}{'stream'} = $3;
            push(@{$self->{'pageVars'}{'opStack'}}, $1);
            shift(@{$self->{'pageVars'}{'opStack'}}) if (scalar(@{$self->{'pageVars'}{'opStack'}}) > 6);
            next;
        }

        # Array operands...
        my $firstChar = substr($self->{'pageVars'}{'stream'}, 0, 1);
        if (($firstChar eq '[') || ($firstChar eq '(')) {
            my $matchChar = ($firstChar eq '[') ? ']' : ')';
            $self->{'pageVars'}{'stream'} =~ m/\A(\Q$firstChar\E.*?(?<!\\)\Q$matchChar\E)\s*([^\s].*)/s;
            $self->{'pageVars'}{'stream'} = $2;
            push(@{$self->{'pageVars'}{'opStack'}}, $1);
            shift(@{$self->{'pageVars'}{'opStack'}}) if (scalar(@{$self->{'pageVars'}{'opStack'}}) > 6);
            next;
        }

        # Character operands...
        if ($firstChar eq '<') {
            $self->{'pageVars'}{'stream'} =~ m/\A(<[^>]+>(\s*<[^>]+>)*)\s*([^\s].*)/s;
            $self->{'pageVars'}{'stream'} = $3;
            push(@{$self->{'pageVars'}{'opStack'}}, $1);
            shift(@{$self->{'pageVars'}{'opStack'}}) if (scalar(@{$self->{'pageVars'}{'opStack'}}) > 6);
            next;
        }

        # Other operands...
        if ($firstChar eq '/') {
            $self->{'pageVars'}{'stream'} =~ m/\A(\/[^\s]+?)\s+([^\s].*)/s;
            $self->{'pageVars'}{'stream'} = $2;
            push(@{$self->{'pageVars'}{'opStack'}}, $1);
            shift(@{$self->{'pageVars'}{'opStack'}}) if (scalar(@{$self->{'pageVars'}{'opStack'}}) > 6);
            next;
        }

        # Operators...
        $self->{'pageVars'}{'stream'} =~ m/\A\s*([^\s]+?)(\s+([^\s].*)|\s*([\[\(<\/].*)|\Z)/s;
        $op = $1;
        if ($3 && $4) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Regex assumption failed.\n";
            return;
        }
        $self->{'pageVars'}{'stream'} = $3 || $4;
        $self->{'pageVars'}{'stream'} =~ s/\A\s*([^\s].*)/$1/s if ($self->{'pageVars'}{'stream'});

        # Painting
        if ($painting) {
            if (!$self->handlePathPaintingOperator($op)) {
                &{$self->{'pathHandler'}}(
                    $self->{'path'}{'segments'}
                    , !$self->{'path'}{'isOpen'}
                    , $self->{'path'}{'isStroked'}
                    , $self->{'path'}{'isFilled'}
                    , $self->{'path'}{'isClipping'}
                    , $self->{'graphicsState'}
                );
                $painting = 0;
            }
            else {
                next;
            }
        }

        # Text object 
        if ($op eq 'BT') {
            $self->{'pageVars'}{'posMatrix'} = [1, 0, 0, 1, 0, 0];
            $self->{'pageVars'}{'lineMatrix'} = [1, 0, 0, 1, 0, 0];
            $inTextObject = 1;
            next;
        }
        if ($op eq 'ET') {
            $inTextObject = 0;
            next;
        }
        if ($inTextObject) {
            if (
                !$self->handleGeneralGraphicsStateOperator($op)
                && !$self->handleColourOperator($op)
                && !$self->handleTextStateOperator($op)
                && !$self->handleTextShowingOperator($op)
                && !$self->handleTextPositioningOperator($op)
            ) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operator '" . (defined $op ? $op : '[undef]') . "' found in text object.\n";
                return;
            }
            next;
        }

        # Path object
        if ($self->handlePathStartOperator($op)) {
            $inPathObject = 1;
            next;
        }
        if ($inPathObject) {
            if ($self->handlePathPaintingOperator($op)) {
                $inPathObject = 0;
                $painting = 1;
            }
            elsif ($self->handleClippingPathOperator($op)) {
                $inPathObject = 0;
                $inClippingPathObject = 1;
            }
            elsif (!$self->handlePathConstructionOperator($op)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operator '" . (defined $op ? $op : '[undef]') . "' found in path object.\n";
                return;
            }
            next;
        }

        # Clipping path object
        if ($inClippingPathObject) {
            if ($self->handlePathPaintingOperator($op)) {
                $inClippingPathObject = 0;
                $painting = 1;
            }
            elsif (!$self->handleClippingPathOperator($op)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operator '" . (defined $op ? $op : '[undef]') . "' found in clipping path object.\n";
                return;
            }
            next;
        }

        # General
        if (
            !$self->handleGeneralGraphicsStateOperator($op)
            && !$self->handleSpecialGraphicsStateOperator($op)
            && !$self->handleColourOperator($op)
            && !$self->handleTextStateOperator($op)
        ) {
            # Anything else should be buffered in case it is an operand...
            push(@{$self->{'pageVars'}{'opStack'}}, $op);
            shift(@{$self->{'pageVars'}{'opStack'}}) if (scalar(@{$self->{'pageVars'}{'opStack'}}) > 6);
        }
    }
    print { $self->{'debugStream'} } "PdfSupport::Core: Completed page processing!\n";
}

sub releasePageMemory {

    my ($self) = @_;

    # Font map
    foreach my $f (keys %{$self->{'fontMap'}}) {
        $self->{'fontMap'}{$f} = undef;
        delete($self->{'fontMap'}{$f});
    }
    $self->{'fontMap'} = undef;
    delete($self->{'fontMap'});

    # Path variables
    foreach my $key (keys %{$self->{'path'}}) {
        $self->{'path'}{$key} = undef;
        delete($self->{'path'}{$key});
    }
    $self->{'path'} = undef;
    delete($self->{'path'});

    # Page working variables
    foreach my $key (keys %{$self->{'pageVars'}}) {
        $self->{'pageVars'}{$key} = undef;
        delete($self->{'pageVars'}{$key});
    }
    $self->{'pageVars'} = undef;
    delete($self->{'pageVars'});

    # Graphics state
    foreach my $gskey ('text', 'stroking', 'nonstroking') {
        foreach my $key (keys %{$self->{'graphicsState'}{$gskey}}) {
            $self->{'graphicsState'}{$gskey}{$key} = undef;
            delete($self->{'graphicsState'}{$gskey}{$key});
        }
    }
    foreach my $key (keys %{$self->{'graphicsState'}}) {
        $self->{'graphicsState'}{$key} = undef;
        delete($self->{'graphicsState'}{$key});
    }
    $self->{'graphicsState'} = undef;
    delete($self->{'graphicsState'});

    # Graphics state stack
    for my $s (0..$#{$self->{'graphicsStateStack'}}) {
        foreach my $gskey ('text', 'stroking', 'nonstroking') {
            foreach my $key (keys %{$self->{'graphicsStateStack'}[$s]{$gskey}}) {
                $self->{'graphicsStateStack'}[$s]{$gskey}{$key} = undef;
                delete($self->{'graphicsStateStack'}[$s]{$gskey}{$key});
            }
        }
        foreach my $key (keys %{$self->{'graphicsStateStack'}[$s]}) {
            $self->{'graphicsStateStack'}[$s]{$key} = undef;
            delete($self->{'graphicsStateStack'}[$s]{$key});
        }
        $self->{'graphicsStateStack'}[$s] = undef;
    }
    $self->{'graphicsStateStack'} = undef;
    delete($self->{'graphicsStateStack'});
}

sub close {

    my ($self) = @_;

    $self->releasePageMemory();

    # PDF document
    $self->{'doc'}->end;
    $self->{'doc'} = undef;
    delete($self->{'doc'});

    $self = undef;

    return undef;
}


#==========================================================
# Handler Subroutines
#==========================================================
# The text handler is passed characters and/or logical strings with
# position information. For right-to-left text:
#   [width, 0, 0, height, x, y]
# For vertical text:
#   [0, height, width, 0, x, y]
# The origin is assumed to be at the bottom left corner of a page.
sub setTextHandler {

    my ($self, $handler) = @_;

    if ((defined $handler) && (ref($handler) ne 'CODE')) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): The text handler is not a subroutine reference.\n";
    }
    elsif (!defined $handler) {
        $handler = \&emptyHandler;
    }
    $self->{'textHandler'} = $handler;
}

# The path handler is passed a set of line segments with painting information:
#   [[segments], is closed, is stroked, is filled, is clipping, graphics state]
# Each line segment looks like:
#   [start x, start y, end x, end y, is straight, [curve parameters]]
# Is filled indicates whether the path is filled as well as what rule is used:
#   0 = not filled
#   1 = non zero winding number rule
#   2 = even-odd rule
sub setPathHandler {

    my ($self, $handler) = @_;

    if ((defined $handler) && (ref($handler) ne 'CODE')) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): The path handler is not a subroutine reference.\n";
    }
    elsif (!defined $handler) {
        $handler = \&emptyHandler;
    }
    $self->{'pathHandler'} = $handler;
}

# Default text/path handler.
sub emptyHandler {
}

sub setDebugStream {

    my ($self, $stream) = @_;

    $self->{'debugStream'} = $stream if (defined $stream);
}


#==========================================================
# Font & Encoding Subroutines
#==========================================================
# Assemble a mapping from font-specific character IDs to unicode code points for each font used in a page.
sub buildFontMap {

    my ($self) = @_;

    my $debugStream = $self->{'debugStream'};
    my $pageFonts = $self->{'pageVars'}{'pageObj'}{'Resources'}{'Font'}->realise;

    # For each font used on the current page of the PDF...
    foreach my $fontName (keys %{$pageFonts}) {
        next if ($fontName =~ m/^\s+/);                # (Skip instance variables.)
        my $font = $pageFonts->{$fontName}->realise;
        next if ($font->{'Type'}->val ne 'Font');    # (Skip non-font objects.)

        # The following code was written to support type 1 and true-type fonts (which seem to be the most common types).
        # In general, simple fonts might be okay but type 0 fonts are definitely not going to be handled correctly. The
        # safest way to proceed is to whitelist font subtypes that we know will work. Debug output will provide as much
        # detail as possible about unsupported fonts.
        # The goal is to end up with $self->{'fontMap'}{$fontName} containing a complete hash of font character IDs to
        # array references containing the unicode code point associated with the CID, and the width of the associated
        # glyph when rendered with the given font.
        print $debugStream "PdfSupport::Core: Building unicode mapping for font '$fontName'...\n";
        $self->{'fontMap'}{$fontName} = undef;
        if (($font->{'Subtype'}->val ne 'Type1') && ($font->{'Subtype'}->val ne 'TrueType')) {
            print $debugStream 'PdfSupport::Core (' . __LINE__ . "): Failed to build a map for font '$fontName' (unhandled font subtype '" . $font->{'Subtype'}->val . "'):\n";
            $self->structure($pageFonts->{$fontName});
            next;
        }

        # First, if a base-font is specified then see if it is a core PDF font with a predefined encoding.
        if (defined $font->{'BaseFont'}) {
            print $debugStream "PdfSupport::Core: Using BaseFont '" . $font->{'BaseFont'}->val . "'.\n";
            eval { $font = $self->{'doc'}->corefont($font->{'BaseFont'}->val); };
            # If the font was recognised, load it. We're especially interested in the to-unicode map [optional]
            # and descriptor.
            if (!$@) {
                $font->realise;
                $font->tounicodemap;
                $font->{'FontDescriptor'} = $font->descrByData if (!defined $font->{'FontDescriptor'});
            }
        }

        # Now if a pre-defined encoding is specified then add that to our fontMap.
        if (defined $font->{'Encoding'}) {
            $font->{'Encoding'}->realise;

            # Sometimes the font only uses the standard pre-defined encoding...
            if (ref($font->{'Encoding'}) =~ m/Name/) {
                my $fontEncoding = $font->{'Encoding'}->val;
                print $debugStream "PdfSupport::Core: Using encoding '$fontEncoding'.\n";
                $self->loadEncoding($fontEncoding) if (!exists $predefEncodingMap{$fontEncoding});
                if (defined $predefEncodingMap{$fontEncoding}) {
                    map { $self->{'fontMap'}{$fontName}{$_} = [$predefEncodingMap{$fontEncoding}{$_}, undef] } keys %{$predefEncodingMap{$fontEncoding}};
                }
            }
            # Sometimes the pre-defined encoding is extended...
            else {
                # Start with the base encoding.
                if (defined $font->{'Encoding'}{'BaseEncoding'}) {
                    my $fontEncoding = $font->{'Encoding'}{'BaseEncoding'}->val;
                    print $debugStream "PdfSupport::Core: Using BaseEncoding '$fontEncoding'.\n";
                    $self->loadEncoding($fontEncoding) if (!exists $predefEncodingMap{$fontEncoding});
                    if (defined $predefEncodingMap{$fontEncoding}) {
                        map { $self->{'fontMap'}{$fontName}{$_} = [$predefEncodingMap{$fontEncoding}{$_}, undef] } keys %{$predefEncodingMap{$fontEncoding}};
                    }
                }

                # Add any differences from the pre-defined encoding to the differences mapping.
                if (defined $font->{'Encoding'}{'Differences'}) {
                    print $debugStream "PdfSupport::Core: Adding encoding differences.\n";
                    my @glyphNames = @{$font->{'Encoding'}{'Differences'}->val};
                    my $index = 0;
                    foreach my $g (0..$#glyphNames) {
                        if (ref($glyphNames[$g]) =~ m/Number/) {
                            $index = $glyphNames[$g]->val;
                        }
                        else {
                            my $unicode = undef;
                            if ($glyphNames[$g]->val ne '.notdef') {    # TODO are we okay about ending up with an undef in the map?
                                $unicode = uniByName($glyphNames[$g]->val);
                                if (!defined $unicode) {
                                    print $debugStream 'PdfSupport::Core (' . __LINE__ . "): The difference map for font '$fontName' required character '" . $glyphNames[$g]->val . "' which has no known unicode mapping.\n";
                                }
                                else {
                                    $unicode = sprintf("%04X", $unicode);
                                }
                            }
                            $self->{'fontMap'}{$fontName}{sprintf("%04X", $g)} = [$unicode, undef];
                            $index++;
                        }
                    }
                }
            }
        }

        # A 'ToUnicode' map is the preferred and authoritative way to translate CIDs to code points however it is only
        # an optional part of a PDF font's structure. Even when it is present a 'ToUnicode' map may not include certain
        # characters if the font is based on a pre-defined encoding. Do this last so we overwrite any existing mappings
        # that we created earlier.
        if (defined $font->{'ToUnicode'}) {
            print $debugStream "PdfSupport::Core: Using ToUnicode map.\n";
            $font->{'ToUnicode'}->realise;

            # Decompress the 'ToUnicode' map stream if necessary.
            my $fontToUnicodeStream = $font->{'ToUnicode'}{' stream'};
            if (!$font->{'ToUnicode'}{' unfilt'}) {
                $fontToUnicodeStream = unfilter($font->{'ToUnicode'}{'Filter'}, $fontToUnicodeStream);
            }

            # Add each chunk of the 'ToUnicode' map to our font map.
            while ($fontToUnicodeStream =~ m/(beginbfchar|beginbfrange)\s*(.*?)\s*(endbfchar|endbfrange)(.*)/s) {
                my $mapChunk = $2;
                $fontToUnicodeStream = $4;

                # There are two ways of specifying a 'ToUnicode' mapping. Direct maps are easy...
                if ($1 eq 'beginbfchar') {
                    while ($mapChunk =~ m/\s*<([^>]+)>\s*<([^>]+)>(.*)/s) {
                        $self->{'fontMap'}{$fontName}{uc(sprintf("%04s", $1))} = [uc(sprintf("%04s", $2)), undef];
                        $mapChunk = $3;
                    }
                }
                # Maps that include ranges are a little more tricky!
                else {
                    while ($mapChunk =~ m/\s*<([^>]+)>\s*<([^>]+)>\s*(.*?)\n(.*)/s) {
                        $mapChunk = $4;
                        my ($start, $end, $range) = (hex($1), hex($2), $3);
                        my $rangeIsSpecific = 1;
                        if ($range =~ m/^\s*<([^>]*)>\s*$/) {
                            $rangeIsSpecific = 0;
                            $range = hex($1);
                        }                        
                        foreach my $i ($start..$end) {
                            if ($rangeIsSpecific) {
                                $range =~ m/.*?<([^>])>(.*)/;
                                $range = $2;
                                $self->{'fontMap'}{$fontName}{sprintf("%04X", $i)} = [sprintf("%04X", $1), undef];
                            }
                            else {
                                $self->{'fontMap'}{$fontName}{sprintf("%04X", $i)} = [sprintf("%04X", $range++), undef];
                            }
                        }
                    }
                }
            }
        }

        # If we get to here and we haven't got a mapping then something went wrong. Maybe the font structure
        # in the PDF doesn't contain enough information to build a map. In any case, spit out the structure
        # for debugging purposes...
        if (!defined $self->{'fontMap'}{$fontName}) {
            print $debugStream 'PdfSupport::Core (' . __LINE__ . "): Failed to build a map for font '$fontName':\n";
            $self->structure($pageFonts->{$fontName});
            next;
        }

        # At this point we have a map of font-specific CIDs to unicode code points. The final thing we have
        # to do is to assign a width to each character in the map.
        $font->{'FontDescriptor'}->realise;
        my $missingWidth = (defined $font->{'FontDescriptor'}{'MissingWidth'}) ? $font->{'FontDescriptor'}{'MissingWidth'}->val : 0;
        foreach my $code (keys %{$self->{'fontMap'}{$fontName}}) {
            my $windex = hex($code) - $font->{'FirstChar'}->val;
            if (($windex < 0) || (hex($code) > $font->{'LastChar'}->val) ||    ($font->{'Widths'}->val->[$windex]->val == 0)) {
                $self->{'fontMap'}{$fontName}{$code}[1] = $missingWidth;
            }
            else {
                $self->{'fontMap'}{$fontName}{$code}[1] = $font->{'Widths'}->val->[$windex]->val;
            }
        }

        print $debugStream "\n";
    }
}

# This subroutine makes a [PDF] pre-defined encoding available to this module.
sub loadEncoding {

    my ($self, $fontEncoding) = @_;

    # Nothing to do if we have already assembled a map for this encoding.
    return if (exists $predefEncodingMap{$fontEncoding});

    $predefEncodingMap{$fontEncoding} = undef;
    # If it exists, the raw encoding will be an array of 255 character names. These names still have to be mapped to unicode code points.
    my $encodingRef = getRawEncoding($fontEncoding);
    if (defined $encodingRef) {
        # For each character name in the encoding...
        foreach my $i (0..$#{$encodingRef}) {
            # If the character name is defined in this encoding, look up the unicode code point associated with the character name.
            my $unicode = undef;
            if (defined ${$encodingRef}[$i]) {
                $unicode = uniByName(${$encodingRef}[$i]);
                if (!defined $unicode) {
                    print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Encoding '$fontEncoding' required character '${$encodingRef}[$i]' which has no known unicode mapping.\n";
                }
                else {
                    $unicode = sprintf("%04X", $unicode);
                }
            }
            $predefEncodingMap{$fontEncoding}{sprintf("%04X", $i)} = $unicode;
        }
    }
}


#==========================================================
# Operator Handlers
#==========================================================
sub handleGeneralGraphicsStateOperator {

    my ($self, $op) = @_;

    # Line width.
    if ($op eq 'w') {
        my $width = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $width) || ($width !~ m/^\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $width ? $width : '[undef]') . "' found where line width (positive number) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'lineWidth'} = $width;
        return 1;
    }

    # Line cap style.
    if ($op eq 'J') {
        my $style = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $style) || (($style != 0) && ($style != 1) && ($style != 2))) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $style ? $style : '[undef]') . "' found where line cap style (0, 1, 2) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'lineCap'} = $style;
        return 1;
    }

    # Line join style.
    if ($op eq 'j') {
        my $style = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $style) || (($style != 0) && ($style != 1) && ($style != 2))) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $style ? $style : '[undef]') . "' found where line join style (0, 1, 2) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'lineJoin'} = $style;
        return 1;
    }

    # Mitre Limit.
    if ($op eq 'M') {
        my $limit = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $limit) || ($limit !~ m/^\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $limit ? $limit : '[undef]') . "' found where mitre limit (positive number) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'mitreLimit'} = $limit;
        return 1;
    }

    # Dash Pattern.
    if ($op eq 'd') {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unsupported operand 'd' (line dash pattern).\n";
        return 1;
    }

    # Rendering Intent.
    if ($op eq 'ri') {
        my $intent = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $intent) || (($intent ne 'AbsoluteColorimetric') && ($intent ne 'RelativeColorimetric') && ($intent ne 'Saturation') && ($intent ne 'Perceptual'))) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $intent ? $intent : '[undef]') . "' found where rendering intent was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'renderingIntent'} = $intent;
        return 1;
    }

    # Flatness Tolerance.
    if ($op eq 'i') {
        my $tolerance = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $tolerance) || ($tolerance !~ m/^\d+(\.\d+)?$/) || ($tolerance > 100)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $tolerance ? $tolerance : '[undef]') . "' found where flatness tolerance (0..100) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'flatnessTolerance'} = $tolerance;
        return 1;
    }

    # Graphics State Dictionary Lookup.
    if ($op eq 'gs') {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unsupported operand 'gs' (graphics state dictionary lookup).\n";
        return 1;
    }

    return 0;
}

sub handleSpecialGraphicsStateOperator {

    my ($self, $op) = @_;

    # Save Graphics State.
    if ($op eq 'q') {
        # Deep copy so that nested structures are stored properly.
        my $gsc = dclone($self->{'graphicsState'});
        push(@{$self->{'graphicsStateStack'}}, $gsc);
        return 1;
    }

    # Restore Graphics State.
    if ($op eq 'Q') {
        $self->{'graphicsState'} = pop(@{$self->{'graphicsStateStack'}});
        return 1;
    }

    # Transformation Matrix.
    if ($op eq 'cm') {
        my @changeMatrix = ();
        for (0..5) {
            my $operand = pop(@{$self->{'pageVars'}{'opStack'}});
            if ((!defined $operand) || ($operand !~ m/^-?\d+(\.\d+)?$/)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $operand ? $operand : '[undef]') . "' found where transformation matrix component (number) was expected.\n";
                return 1;
            }
            unshift(@changeMatrix, $operand);
        }
        $self->{'graphicsState'}{'CTM'} = matrixMultiply(\@changeMatrix, $self->{'graphicsState'}{'CTM'});
        return 1;
    }

    return 0;
}

sub handlePathStartOperator {

    my ($self, $op) = @_;

    # Start Path.
    if ($op eq 'm') {
        $self->{'path'}{'segments'} = [];
        $self->{'path'}{'isOpen'} = 1;
        $self->{'path'}{'isStroked'} = 0;
        $self->{'path'}{'isFilled'} = 0;
        $self->{'path'}{'isClipping'} = 0;
        my $y = pop(@{$self->{'pageVars'}{'opStack'}});
        my $x = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $x) || ($x !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $x ? $x : '[undef]') . "' found where subpath start x (positive number) was expected.\n";
            return 1;
        }
        if ((!defined $y) || ($y !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $y ? $y : '[undef]') . "' found where subpath start y (positive number) was expected.\n";
            return 1;
        }
        $self->{'path'}{'currentX'} = $x;
        $self->{'path'}{'currentY'} = $y;
        return 1;
    }

    # Append Rectangle.
    if ($op eq 're') {
        $self->{'path'}{'segments'} = [];
        $self->{'path'}{'isOpen'} = 1;
        $self->{'path'}{'isStroked'} = 0;
        $self->{'path'}{'isFilled'} = 0;
        $self->{'path'}{'isClipping'} = 0;
        my $h = pop(@{$self->{'pageVars'}{'opStack'}});
        my $w = pop(@{$self->{'pageVars'}{'opStack'}});
        my $y = pop(@{$self->{'pageVars'}{'opStack'}});
        my $x = pop(@{$self->{'pageVars'}{'opStack'}});
        addPathSegment($self, $x, $y, $x + $w, $y, 1, undef);
        addPathSegment($self, $x + $w, $y, $x + $w, $y + $h, 1, undef);
        addPathSegment($self, $x + $w, $y + $h, $x, $y + $h, 1, undef);
        addPathSegment($self, $x, $y + $h, $x, $y, 1, undef);
        $self->{'path'}{'isOpen'} = 0;
        return 1;
    }

    return 0;
}

sub handlePathConstructionOperator {

    my ($self, $op) = @_;

    # Append Line.
    if ($op eq 'l') {
        my $y = pop(@{$self->{'pageVars'}{'opStack'}});
        my $x = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $x) || ($x !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $x ? $x : '[undef]') . "' found where line x (positive number) was expected.\n";
            return 1;
        }
        if ((!defined $y) || ($y !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $y ? $y : '[undef]') . "' found where line y (positive number) was expected.\n";
            return 1;
        }
        addPathSegment(
            $self
            , $self->{'path'}{'currentX'}
            , $self->{'path'}{'currentY'}
            , $x
            , $y
            , 1
            , undef
        );
        $self->{'path'}{'currentX'} = $x;
        $self->{'path'}{'currentY'} = $y;
        return 1;
    }

    # Append Curve.
    if ($op eq 'c') {
        my @parameters = ();
        foreach (0..5) {
            my $operand = pop(@{$self->{'pageVars'}{'opStack'}});
            if ((!defined $operand) || ($operand !~ m/^\d+(\.\d+)?$/)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $operand ? $operand : '[undef]') . "' found where curve parameter (positive number) was expected.\n";
                return 1;
            }
            unshift(@parameters, $operand);
        }
        addPathSegment(
            $self
            , $self->{'path'}{'currentX'}
            , $self->{'path'}{'currentY'}
            , $parameters[4]
            , $parameters[5]
            , 0
            , \@parameters[0..3]
        );
        $self->{'path'}{'currentX'} = $parameters[4];
        $self->{'path'}{'currentY'} = $parameters[5];
        return 1;
    }

    if ($op eq 'v') {
        my @parameters = ();
        foreach my $operand (0..3) {
            my $o = pop(@{$self->{'pageVars'}{'opStack'}});
            if ((!defined $o) || ($o !~ m/^\d+(\.\d+)?$/)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $o ? $o : '[undef]') . "' found where curve parameter (positive number) was expected.\n";
                return 1;
            }
            unshift(@parameters, $o);
        }
        addPathSegment(
            $self
            , $self->{'path'}{'currentX'}
            , $self->{'path'}{'currentY'}
            , $parameters[2]
            , $parameters[3]
            , 0
            , [$self->{'path'}{'currentX'}, $self->{'path'}{'currentY'}, $parameters[0], $parameters[1]]
        );
        $self->{'path'}{'currentX'} = $parameters[2];
        $self->{'path'}{'currentY'} = $parameters[3];
        return 1;
    }

    if ($op eq 'y') {
        my @parameters = ();
        foreach my $operand (0..3) {
            my $o = pop(@{$self->{'pageVars'}{'opStack'}});
            if ((!defined $o) || ($o !~ m/^\d+(\.\d+)?$/)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $o ? $o : '[undef]') . "' found where curve parameter (positive number) was expected.\n";
                return 1;
            }
            unshift(@parameters, $o);
        }
        addPathSegment(
            $self
            , $self->{'path'}{'currentX'}
            , $self->{'path'}{'currentY'}
            , $parameters[2]
            , $parameters[3]
            , 0
            , \@parameters[0..3]
        );
        $self->{'path'}{'currentX'} = $parameters[2];
        $self->{'path'}{'currentY'} = $parameters[3];
        return 1;
    }

    # Close Path.
    if ($op eq 'h') {
        # Subpath already closed?
        if ($self->{'path'}{'isOpen'} == 0) {
            return 1;
        }

        my $x = $self->{'path'}{'currentX'};
        my $y = $self->{'path'}{'currentY'};
        if ((defined $self->{'path'}{'segments'}) && (scalar(@{$self->{'path'}{'segments'}}) > 0)) {
            $x = $self->{'path'}{'segments'}[0]{'x1'};
            $y = $self->{'path'}{'segments'}[0]{'y1'};
        }
        addPathSegment(
            $self
            , $self->{'path'}{'currentX'}
            , $self->{'path'}{'currentY'}
            , $x
            , $y
            , 1
            , undef
        );
        $self->{'path'}{'currentX'} = $x;
        $self->{'path'}{'currentY'} = $y;
        $self->{'path'}{'isOpen'} = 0;
        return 1;
    }

    return 0;
}

sub handlePathPaintingOperator {

    my ($self, $op) = @_;

    # Close Path.
    if (($op eq 's') || ($op eq 'f') || ($op eq 'B') || ($op eq 'b') || ($op eq 'b*')) {
        if ($self->{'path'}{'isOpen'} == 1) {
            my $x = $self->{'path'}{'currentX'};
            my $y = $self->{'path'}{'currentY'};
            if ((defined $self->{'path'}{'segments'}) && (scalar(@{$self->{'path'}{'segments'}}) > 0)) {
                $x = $self->{'path'}{'segments'}[0]{'x1'};
                $y = $self->{'path'}{'segments'}[0]{'y1'};
            }
            addPathSegment(
                $self
                , $self->{'path'}{'currentX'}
                , $self->{'path'}{'currentY'}
                , $x
                , $y
                , 1
                , undef
            );
            $self->{'path'}{'currentX'} = $x;
            $self->{'path'}{'currentY'} = $y;
            $self->{'path'}{'isOpen'} = 0;
        }
    }

    # Stroke Path.
    if (($op eq 'S') || ($op eq 's')) {
        $self->{'path'}{'isStroked'} = 1;
        return 1;
    }

    # Fill Path.
    if (($op eq 'f') || ($op eq 'F')) {
        $self->{'path'}{'isFilled'} = 1;
        return 1;
    }
    if ($op eq 'f*') {
        $self->{'path'}{'isFilled'} = 2;
        return 1;
    }

    # Fill Then Stroke Path.
    if (($op eq 'B') || ($op eq 'b')) {
        $self->{'path'}{'isFilled'} = 1;
        $self->{'path'}{'isStroked'} = 1;
        return 1;
    }
    if (($op eq 'B*') || ($op eq 'b*')) {
        $self->{'path'}{'isFilled'} = 2;
        $self->{'path'}{'isStroked'} = 1;
        return 1;
    }

    # Finish Path.
    if ($op eq 'n') {
        $self->{'path'}{'isFilled'} = 0;
        $self->{'path'}{'isStroked'} = 0;
        return 1;
    }

    return 0;
}

sub handleClippingPathOperator {

    my ($self, $op) = @_;

    if ($op eq 'W') {
        push(@{$self->{'graphicsState'}{'clippingPath'}}, [$self->{'path'}{'segments'}, 0]);
        $self->{'path'}{'isClipping'} = 1;
        return 1;
    }
    if ($op eq 'W*') {
        push(@{$self->{'graphicsState'}{'clippingPath'}}, [$self->{'path'}{'segments'}, 1]);
        $self->{'path'}{'isClipping'} = 1;
        return 1;
    }

    return 0;
}

sub handleTextStateOperator {

    my ($self, $op) = @_;

    if (($op ne 'Tc') && ($op ne 'Tw') && ($op ne 'Tz') && ($op ne 'TL') && ($op ne 'Tf') && ($op ne 'Tr') && ($op ne 'Ts')) {
        return 0;
    }

    if ($op eq 'Tf') {
        my $size = pop(@{$self->{'pageVars'}{'opStack'}});
        my $font = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $size) || ($size !~ m/^\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $size ? $size : '[undef]') . "' found where font size (positive number) was expected.\n";
            return 1;
        }
        if ((!defined $font) || ($font !~ m/^\/([^\s]+)$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $font ? $font : '[undef]') . "' found where font name was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'text'}{'fontSize'} = $size;
        $self->{'graphicsState'}{'text'}{'fontName'} = $1;
        return 1;
    }

    my $operand = pop(@{$self->{'pageVars'}{'opStack'}});
    if ((!defined $operand) || ($operand !~ m/^-?\d+(\.\d+)?$/)) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $operand ? $operand : '[undef]') . "' found where text state operand (number) was expected.\n";
        return 1;
    }

    if ($op eq 'Tc') {
        $self->{'graphicsState'}{'text'}{'characterSpacing'} = $operand;
    }
    elsif ($op eq 'Tw') {
        $self->{'graphicsState'}{'text'}{'wordSpacing'} = $operand;
    }
    elsif ($op eq 'Tz') {
        $self->{'graphicsState'}{'text'}{'horizontalScaling'} = $operand / 100;
    }
    elsif ($op eq 'TL') {
        $self->{'graphicsState'}{'text'}{'leading'} = $operand;
    }
    elsif ($op eq 'Tr') {
        $self->{'graphicsState'}{'text'}{'renderMode'} = $operand;
    }
    elsif ($op eq 'Ts') {
        $self->{'graphicsState'}{'text'}{'rise'} = $operand;
    }
    return 1;
}

sub handleTextPositioningOperator {

    my ($self, $op) = @_;

    if (($op eq 'Td') || ($op eq 'TD')) {
        my $y = pop(@{$self->{'pageVars'}{'opStack'}});
        my $x = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $x) || ($x !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $x ? $x : '[undef]') . "' found where text positioning operand (number) was expected.\n";
            return 1;
        }
        if ((!defined $y) || ($y !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $y ? $y : '[undef]') . "' found where text positioning operand (number) was expected.\n";
            return 1;
        }
        if ($op eq 'TD') {
            $self->{'graphicsState'}{'text'}{'leading'} = $y * -1;
        }
        $self->newLine($x, $y);
        return 1;
    }

    if ($op eq 'Tm') {
        my @matrix = ();
        foreach (0..5) {
            my $operand = pop(@{$self->{'pageVars'}{'opStack'}});
            if ((!defined $operand) || ($operand !~ m/^-?\d+(\.\d+)?$/)) {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $operand ? $operand : '[undef]') . "' found where text positioning operand (number) was expected.\n";
                return 1;
            }
            unshift(@matrix, $operand);
        }
        @{$self->{'pageVars'}{'posMatrix'}} = @matrix;
        @{$self->{'pageVars'}{'lineMatrix'}} = @matrix;
        return 1;
    }

    if ($op eq 'T*') {
        $self->newLine(0, $self->{'graphicsState'}{'text'}{'leading'} * -1);
        return 1;
    }

    return 0;
}

sub handleTextShowingOperator {

    my ($self, $op) = @_;

    if (($op ne 'Tj') && ($op ne "'") && ($op ne '"') && ($op ne 'TJ')) {
        return 0;
    }

    my $estring = pop(@{$self->{'pageVars'}{'opStack'}});

    if ($op eq '"') {
        my $cs = pop(@{$self->{'pageVars'}{'opStack'}});
        my $ws = pop(@{$self->{'pageVars'}{'opStack'}});
        if ((!defined $cs) || ($cs !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $cs ? $cs : '[undef]') . "' found where character spacing (number) was expected.\n";
            return 1;
        }
        if ((!defined $ws) || ($ws !~ m/^-?\d+(\.\d+)?$/)) {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected operand '" . (defined $ws ? $ws : '[undef]') . "' found where word spacing (number) was expected.\n";
            return 1;
        }
        $self->{'graphicsState'}{'text'}{'characterSpacing'} = $cs;
        $self->{'graphicsState'}{'text'}{'wordSpacing'} = $ws;
        $self->newLine(0, $self->{'graphicsState'}{'text'}{'leading'} * -1);
    }

    if ($op eq "'") {
        $self->newLine(0, $self->{'graphicsState'}{'text'}{'leading'} * -1);
    }

    if (($op eq 'Tj') || ($op eq "'") || ($op eq '"')) {
        my ($string, $width) = (substr($estring, 0, 1) eq '(') ? $self->readString($estring) : $self->readChars($estring);
        my $positionInfo = [$width, 0, 0, $self->{'graphicsState'}{'text'}{'fontSize'}, 0, $self->{'graphicsState'}{'text'}{'rise'}];
        $positionInfo = matrixMultiply($positionInfo, $self->{'pageVars'}{'posMatrix'});
        $positionInfo = matrixMultiply($positionInfo, $self->{'graphicsState'}{'CTM'});
        &{$self->{'textHandler'}}($string, $positionInfo);

        ${$self->{'pageVars'}{'posMatrix'}}[4] += $width;
    }
    elsif ($op eq 'TJ') {
        $estring = substr($estring, 1, -1);

        my $string = '';
        my $width = 0;
        while ($estring ne '') {
            # The next character tells us what to do!
            my $firstChar = substr($estring, 0, 1);

            # Text follows...
            my ($s, $w);
            if ($firstChar eq '(') {
                ($s, $w) = $self->readString($estring);
                $estring =~ s/\A.*?(?<!\\)\)(.*)/$1/s;
                $string .= $s;
                $width += $w;
            }
            elsif ($firstChar eq '<') {
                ($s, $w) = $self->readChars($estring);
                $estring =~ s/\A.*?>(.*)/$1/s;
                $string .= $s;
                $width += $w;
            }
            elsif (($firstChar eq '-') || ($firstChar =~ m/\d/)) {
                # Some TJ clauses print multiple "logical" strings, using the adjustment to provide
                # the required separation. These strings have to be unpacked carefully...
                $estring =~ s/\A(-?\d+(\.\d+)?)\s*(.*)/$3/s;
                my $rawAdjustment = $1;
                my $adjustment = $self->{'graphicsState'}{'text'}{'fontSize'} * $self->{'graphicsState'}{'text'}{'horizontalScaling'} * $rawAdjustment / 1000; 

                # We've reached the end of a logical string. 
                if (abs($rawAdjustment) > $self->{'logicalStringSeparation'}) {
                    # Calculate the final dimensions of the string then call the handler.
                    my $positionInfo = [$width, 0, 0, $self->{'graphicsState'}{'text'}{'fontSize'}, 0, $self->{'graphicsState'}{'text'}{'rise'}];
                    $positionInfo = matrixMultiply($positionInfo, $self->{'pageVars'}{'posMatrix'});
                    $positionInfo = matrixMultiply($positionInfo, $self->{'graphicsState'}{'CTM'});
                    &{$self->{'textHandler'}}($string, $positionInfo);

                    # Update the text position, including the adjustment. Leave the line matrix alone!
                    ${$self->{'pageVars'}{'posMatrix'}}[4] += ($width - $adjustment);

                    # Reset the working variables.
                    $string = '';
                    $width = 0;
                }

                # Otherwise this just a regular character adjustment.
                else {
                    $width -= $adjustment;
                }
            }
            else {
                print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unexpected first character '$firstChar' in TJ clause processing.\n";
            }
        }
        if ($string ne '') {
            my $positionInfo = [$width, 0, 0, $self->{'graphicsState'}{'text'}{'fontSize'}, 0, $self->{'graphicsState'}{'text'}{'rise'}];
            $positionInfo = matrixMultiply($positionInfo, $self->{'pageVars'}{'posMatrix'});
            $positionInfo = matrixMultiply($positionInfo, $self->{'graphicsState'}{'CTM'});
            &{$self->{'textHandler'}}($string, $positionInfo);

            ${$self->{'pageVars'}{'posMatrix'}}[4] += $width;
        }
    }

    return 1;
}

sub handleColourOperator {

    my ($self, $op) = @_;

    # Set a colour space and default colour.
    if (($op eq 'CS') || ($op eq 'cs')) {
        my $spaceType = ($op eq 'CS') ? 'stroking' : 'nonstroking';
        my $spaceName = pop(@{$self->{'pageVars'}{'opStack'}});
        $self->{'graphicsState'}{$spaceType}{'colourSpace'} = $spaceName;
        if ($spaceName eq 'DeviceGray') {
            $self->{'graphicsState'}{$spaceType}{'colour'} = [0];
        }
        elsif ($spaceName eq 'DeviceRGB') {
            $self->{'graphicsState'}{$spaceType}{'colour'} = [0, 0, 0];
        }
        elsif ($spaceName eq 'DeviceCMYK') {
            $self->{'graphicsState'}{$spaceType}{'colour'} = [0, 0, 0, 1];
        }
        else {
            print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unsupported colour space '$spaceName' encountered.\n";
        }
        return 1;
    }
    if (($op eq 'SC') || ($op eq 'SCN') || ($op eq 'sc') || ($op eq 'scn')) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): Unsupported colour space operator '$op' encountered.\n";
        return 1;
    }

    # DeviceGray
    if (($op eq 'G') || ($op eq 'g')) {
        my $spaceType = ($op eq 'G') ? 'stroking' : 'nonstroking';
        $self->{'graphicsState'}{$spaceType}{'colourSpace'} = 'DeviceGray';
        $self->{'graphicsState'}{$spaceType}{'colour'} = [pop(@{$self->{'pageVars'}{'opStack'}})];
        return 1;
    }

    # RGB
    if (($op eq 'RG') || ($op eq 'rg')) {
        my $spaceType = ($op eq 'RG') ? 'stroking' : 'nonstroking';
        $self->{'graphicsState'}{$spaceType}{'colourSpace'} = 'DeviceRGB';
        my @colour = ();
        foreach (0..2) {
            unshift(@colour, pop(@{$self->{'pageVars'}{'opStack'}}));
        }
        $self->{'graphicsState'}{$spaceType}{'colour'} = \@colour;
        return 1;
    }

    # CMYK
    if (($op eq 'K') || ($op eq 'k')) {
        my $spaceType = ($op eq 'K') ? 'stroking' : 'nonstroking';
        $self->{'graphicsState'}{$spaceType}{'colourSpace'} = 'DeviceCMYK';
        my @colour = ();
        foreach (0..3) {
            unshift(@colour, pop(@{$self->{'pageVars'}{'opStack'}}));
        }
        $self->{'graphicsState'}{$spaceType}{'colour'} = \@colour;
        return 1;
    }

    return 0;
}


#==========================================================
# String/Character Handlers
#==========================================================
sub readChars {

    my ($self, $estring) = @_;

    if (!exists $self->{'fontMap'}{$self->{'graphicsState'}{'text'}{'fontName'}}) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): No font map found for font '" . $self->{'graphicsState'}{'text'}{'fontName'} . "'. Giving up reading these characters.\n";
        return ('', 0);
    }

    # For each '<xxx>' clause...
    my ($string, $width, $spaceCount, $charCount) = ('', 0, 0, 0);
    while ($estring =~ m/\A\s*<([^>]+)>\s*(.*)/s) {
        $estring = $2;
        my $nextChar = $1;

        # All characters in simple fonts have single byte characters (type 0 fonts not supported).
        while ($nextChar ne '') {
            my $currChar = substr($nextChar, 0, 2);
            $nextChar = substr($nextChar, 2);

            my @charInfo = @{  $self->{'fontMap'}{$self->{'graphicsState'}{'text'}{'fontName'}}{'00' . uc($currChar)}  };
            $charInfo[0] = eval("\"\\x{" . $charInfo[0] . '}"');
            $string .= $charInfo[0];
            $width += $charInfo[1];
            $charCount++;
            $spaceCount++ if ($charInfo[0] eq ' ');
        }
    }

    $width = (
        $self->{'graphicsState'}{'text'}{'horizontalScaling'}
        * (
            ($width * $self->{'graphicsState'}{'text'}{'fontSize'} / 1000)
            + ($charCount * $self->{'graphicsState'}{'text'}{'characterSpacing'})
            + ($spaceCount * $self->{'graphicsState'}{'text'}{'wordSpacing'})
        )
    );
    return ($string, $width);
}

sub readString {

    my ($self, $estring) = @_;

    if (!exists $self->{'fontMap'}{$self->{'graphicsState'}{'text'}{'fontName'}}) {
        print { $self->{'debugStream'} } 'PdfSupport::Core (' . __LINE__ . "): No font map found for font '" . $self->{'graphicsState'}{'text'}{'fontName'} . "'. Giving up reading this string.\n";
        return ('', 0);
    }

    # For each '(xxx)' clause...
    my ($string, $width, $charCount, $spaceCount) = ('', 0, 0, 0);
    while ($estring =~ m/\A\s*\((.*?)(?<!\\)\)\s*(.*)/s) {
        $estring = $2;
        my $nextCharset = $1;

        while ($nextCharset ne '') {
            my $nextChar = substr($nextCharset, 0, 1);
            $nextCharset = substr($nextCharset, 1);

            # Deal with literal special character sequences (eg. "\n") and escaping.
            if ($nextChar eq "\\") {
                $nextChar = eval("\"\\" . substr($nextCharset, 0, 1) . '"');
                $nextCharset = substr($nextCharset, 1);
            }
            my @charInfo = @{  $self->{'fontMap'}{$self->{'graphicsState'}{'text'}{'fontName'}}{sprintf("%04X", ord($nextChar))}  };
            $charInfo[0] = eval("\"\\x{" . $charInfo[0] . '}"');
            $string .= $charInfo[0];
            $width += $charInfo[1];
            $charCount++;
            $spaceCount++ if ($charInfo[0] eq ' ');
        }
    }

    $width = (
        $self->{'graphicsState'}{'text'}{'horizontalScaling'}
        * (
            ($width * $self->{'graphicsState'}{'text'}{'fontSize'} / 1000)
            + ($charCount * $self->{'graphicsState'}{'text'}{'characterSpacing'})
            + ($spaceCount * $self->{'graphicsState'}{'text'}{'wordSpacing'})
        )
    );
    return ($string, $width);
}

sub newLine {

    my ($self, $xOffset, $yOffset) = @_;
    
    my $x = $xOffset * ${$self->{'pageVars'}{'lineMatrix'}}[0] + $yOffset * ${$self->{'pageVars'}{'lineMatrix'}}[2] + ${$self->{'pageVars'}{'lineMatrix'}}[4];
    my $y = $xOffset * ${$self->{'pageVars'}{'lineMatrix'}}[1] + $yOffset * ${$self->{'pageVars'}{'lineMatrix'}}[3] + ${$self->{'pageVars'}{'lineMatrix'}}[5];
    ${$self->{'pageVars'}{'lineMatrix'}}[4] = $x;
    ${$self->{'pageVars'}{'lineMatrix'}}[5] = $y;
    @{$self->{'pageVars'}{'posMatrix'}} = @{$self->{'pageVars'}{'lineMatrix'}};
}


#==========================================================
# Other
#==========================================================
sub addPathSegment {

    my ($self, $x1, $y1, $x2, $y2, $isStraight, $curveParams) = @_;

    push(@{$self->{'path'}{'segments'}}, {
        'x1' => $x1
        , 'y1' => $y1
        , 'x2' => $x2
        , 'y2' => $y2
        , 'isStraight' => $isStraight
        , 'curveParams' => $curveParams
    });
}

sub matrixMultiply {

    my ($m1, $m2) = @_;

    my @toReturn;

    # Matrix encoding:
    # 0 1 [0]
    # 2 3 [0]
    # 4 5 [1]

    $toReturn[0] = ${$m1}[0]*${$m2}[0] + ${$m1}[1]*${$m2}[2];
    $toReturn[1] = ${$m1}[0]*${$m2}[1] + ${$m1}[1]*${$m2}[3];
    $toReturn[2] = ${$m1}[2]*${$m2}[0] + ${$m1}[3]*${$m2}[2];
    $toReturn[3] = ${$m1}[2]*${$m2}[1] + ${$m1}[3]*${$m2}[3];
    $toReturn[4] = ${$m1}[4]*${$m2}[0] + ${$m1}[5]*${$m2}[2] + ${$m2}[4];
    $toReturn[5] = ${$m1}[4]*${$m2}[1] + ${$m1}[5]*${$m2}[3] + ${$m2}[5];
    return \@toReturn;
}


#==========================================================
# Debugging
#==========================================================
# A debugging routine for printing out the contents of a hash of array of hash of... etc.
sub structure {

    my ($self, $obj) = @_;

    # Initialise the recursion keys. These prevent recursing too
    # deeply into the document structure as we traverse it.
    $self->{'pageVars'}{'recursiveApiKeys'} = {
        ' api'          => 1
        , 'pages'       => 1
        , 'pdf'         => 1
        , 'Parent'      => 1
        , ' parent'     => 1
        , ' apipdf'     => 1
        , ' apipage'    => 1
    };
    $self->dismantle($obj, '');
}

sub dismantle {

    my ($self, $obj, $spacing) = @_;

    if (!defined $obj) {
        return;
    }
    my $ref = sprintf($obj);
    my $debugStream = $self->{'debugStream'};

    if (($ref =~ m/HASH/) || ($ref =~ m/PDF::Dict/)) {
        $spacing .= "\t";
        print $debugStream "\n";
        foreach my $k (sort {lc($a) cmp lc($b)} keys %{$obj}) {
            my $do = 1;
            foreach my $b (keys %{$self->{'pageVars'}{'recursiveApiKeys'}}) {
                if ($b eq $k) {
                    if ($self->{'pageVars'}{'recursiveApiKeys'}{$k} == 1) {
                        $do = 0;
                    }
                    else {
                        $self->{'pageVars'}{'recursiveApiKeys'}{$k} = 1;
                    }
                    last;
                }
            }
            next if ($do != 1);
            print $debugStream "$spacing$k => ";
            if ($k eq ' stream') {
                print $debugStream "[binary stream]";
            }
            else {
                $self->dismantle(${$obj}{$k}, $spacing);
            }
            print $debugStream "\n"
        }
        $spacing = substr($spacing, 0, -1);
    }
    elsif ($ref =~ m/ARRAY/) {
        $spacing .= "\t";
        print $debugStream "\n";
        foreach my $i (0..$#{$obj}) {
            print $debugStream "$spacing$i: ";
            $self->dismantle(${$obj}[$i], $spacing);
            print $debugStream "\n";
        }
        $spacing = substr($spacing, 0, -1);
    }
    else {
        print $debugStream $obj;
    }
}

1;