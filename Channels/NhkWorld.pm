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

package XmlTv::NzSatEpg::Channels::NhkWorld;

use DateTime;
use XML::Parser;

sub getChannelData {

    print $::dbg "NHK: Starting data grab...\n";

    # Download the schedule that is provided. We don't have any control over what we get, however
    # we seem to be given a 7+ day schedule in the Asia/Tokyo time zone (UTC+9).
    my $response = $::wua->get('http://www3.nhk.or.jp/nhkworld/english/epg/nhkworld_program.xml');
    if ($response->is_error()) {
        print $::dbg 'NHK (' . __LINE__ . '): The request for the schedule XML failed. ' . $response->status_line() . "\n";
        return undef;
    }

    # Set up an XML parser with handlers to handle the parsing events that are important to us.
    my %schedule = ();
    my $progStartDateTime;
    my $parser = new XML::Parser();
    my (@prevProgDetails, @progDetails);
    my ($prevElementContent, $isFirstProgramme) = ('', 1);
    $parser->setHandlers('End', sub {
        my ($expat, $type) = @_;
        if ($prevElementContent !~ m/^\s*$/s) {
            if ($type eq 'pubDate') {
                if ($isFirstProgramme) {
                    $isFirstProgramme = 0;
                    $prevElementContent =~ m/,\s+(\d+)\s+([^\s]*)\s+(\d+)\s+(\d+):(\d+)/;
                    $progStartDateTime = DateTime->new(year => $3, month => $::monthMap{$2}, day => $1, hour => $4, minute => $5, time_zone => 'Asia/Tokyo');
                    $progStartDateTime->set_time_zone('Pacific/Auckland');
                    @prevProgDetails = @progDetails;
                }
                else {
                    $prevElementContent =~ m/,\s+(\d+)\s+([^\s]*)\s+(\d+)\s+(\d+):(\d+)/;
                    my $progEndDateTime = DateTime->new(year => $3, month => $::monthMap{$2}, day => $1, hour => $4, minute => $5, time_zone => 'Asia/Tokyo');
                    $progEndDateTime->set_time_zone('Pacific/Auckland');

                    if ($progEndDateTime > $::startDate && $progStartDateTime < $::endDate) {
                        my $progStartTimeString = $progStartDateTime->strftime("%Y%m%d%H%M");
                        my $p = {
                            'title' => $prevProgDetails[0]
                            , 'start' => $progStartTimeString
                            , 'end' => $progEndDateTime->strftime("%Y%m%d%H%M")
                            , 'description' => $prevProgDetails[1]
                        };
                        if (defined $prevProgDetails[2]) {
                            $p->{'url'} = [$prevProgDetails[2]];
                        }
                        $schedule{$progStartTimeString} = $p;
                    }

                    @prevProgDetails = @progDetails;
                    @progDetails = ();
                    $progStartDateTime = $progEndDateTime;
                }
            }
            else {
                $prevElementContent =~ m/^\s*(.+?)\s*$/s;
                my $content = $1;
                if ($type eq 'title') {
                    $progDetails[0] = $content;
                }
                elsif ($type eq 'description') {
                    $progDetails[1] = $content;
                }
                elsif ($type eq 'link') {
                    $progDetails[2] = $content;
                }
            }
        }
        $prevElementContent = '';
    });
    $parser->setHandlers('Char', sub {
        my ($expat, $string) = @_;
        $prevElementContent .= $string;
    });

    # Parse the XML schedule, printing the details for one programme as another starts.
    print $::dbg "NHK: Processing the schedule.\n";
    $parser->parse($response->content);

    # We miss the last programme - tough cookies.

    return [
        {
            'id' => 'nhk.optus_d2.xmltv.org'
            , 'name' => 'NHK World'
            , 'url' => [
                'http://www3.nhk.or.jp/nhkworld/index.html'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;