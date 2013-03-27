Purpose
--------
This program assembles schedule information for television channels that are
broadcast in New Zealand and Australia via satellite. The output file is an
XMLTV format plaintext file which can be interpretted by a huge variety of HTPC
applications. See http://wiki.xmltv.org/index.php/XMLTVFormat for more details.

License
--------
This program is released under the GNU Affero GPL licence. I chose this licence
because I want anybody to be able to use, maintain and extend the program, and
for the program to be free (libre) even if it is hosted on a server as part of
some kind of service.

Please see Licence.txt for the full licence. You can find more details about
the licence at the following URL:
http://www.gnu.org/licenses/agpl.html

Dependencies
-------------
This program was developed on a PC running Microsoft Windows XP with ActivePerl
5 using the Perl programming language. Your operating system will need a Perl
interpretter to run the program. Most operating systems that are based on Unix
or Linux include a suitable interpretter. Windows does not, but interpretters
such as ActivePerl are available.

You will need to install the following Perl modules:
- DateTime
- Exporter
- JSON
- PDF::API2
- Spreadsheet::ParseExcel
- Storable
- String::Similarity
- XML::Parser

These modules are widely available via CPAN and other Perl package management
systems.

In addition, the Inspiration grabber requires the GhostScript program.
GhostScript is used to convert PDFs created with advanced encoding features to
PDF 1.4 compatible equivalents, enabling them to be read by PDF::API2.
GhostScript is available for Windows and Linux operating systems. Please see
the following URL for more details:
http://www.ghostscript.com

Installation
-------------
Download/unzip the programme scripts into any local directory and install the
dependencies listed above. Nothing further is required.

Configuration
--------------
Open NzSatEpg.pl in any text editor and edit the values of the variables listed
in the "important variables" section to your preference. Then save and close.

You can speed up grabbing by disabling grabbing of data for channels that you
aren't interested in by commenting out the corresponding call to
printChannelData(). For example, to disable grabbing for Amazing Discoveries,
insert a hash (#) at the start of the corresponding line:

#printChannelData(XmlTv::NzSatEpg::Channels::AmazingDiscoveries::getChannelData());

Execution
----------
Use the a terminal, DOS prompt or command line environment to execute
NzSatEpg.pl. For example:

cd "c:\Program Files\NzSatEpg"
perl NzSatEpg.pl

Expect grabbing to take about 5 minutes for all channels.

Debugging
----------
The script is normally very terse. It will print version, licence and copyright
information at startup and a success message on completion. To get more verbose
output, set a DEBUG_NZSATEPG variable.

Version
--------
See Version.txt for the current version number and release notes.

Contact
--------
I prefer to keep my name and contact details private. You can contact me
indirectly and request support at the Geekzone forum:
http://www.geekzone.co.nz/forums.asp?forumid=126&topicid=114552
http://www.geekzone.co.nz/user_public.asp?user_id=34344