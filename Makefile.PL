use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'TiddlyWeb::Wikrad',
    AUTHOR              => 'Chris Dent <cdent@peermore.com>',
    VERSION_FROM        => 'lib/TiddlyWeb/Wikrad.pm',
    ABSTRACT_FROM       => 'lib/TiddlyWeb/Wikrad.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Curses::UI'                  => '0.95',
        'JSON'                        => '0',
    },
    EXE_FILES           => ['bin/twikrad'],
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'TiddlyWeb-Wikrad-*' },
);