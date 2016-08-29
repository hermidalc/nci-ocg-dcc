package NCI::OCGDCC::Config;

use strict;
use warnings;
use Const::Fast;
require Exporter;

our @ISA = qw(Exporter);

our @EXPORT_OK = qw(
    $OCG_CASE_REGEXP
    $OCG_CGI_CASE_DIR_REGEXP
    $OCG_BARCODE_REGEXP
    $CACHE_DIR
);

our %EXPORT_TAGS = ( 
    all => \@EXPORT_OK,
);
our $VERSION = '0.1';

const our $OCG_CASE_REGEXP          => qr/[A-Z]+-\d{2}(?:-\d{2})?-[A-Z0-9]+/;
const our $OCG_CGI_CASE_DIR_REGEXP  => qr/${OCG_CASE_REGEXP}(?:(?:-|_)\d+)?/;
const our $OCG_BARCODE_REGEXP       => qr/${OCG_CASE_REGEXP}-\d{2}(?:\.\d+)?[A-Z]-\d{2}[A-Z]/;

const our $CACHE_DIR                => "$ENV{'HOME'}/.ocg-dcc";

1;
