package TiddlyWeb::Resting;

use strict;
use warnings;

use URI::Escape;
use LWP::UserAgent;
use HTTP::Request;
use Class::Field 'field';
use JSON::XS;

use Readonly;

our $VERSION = '0.1';

=head1 NAME

TiddlyWeb::Resting - module for accessing Socialtext REST APIs

=head1 SYNOPSIS

  use TiddlyWeb::Resting;
  my $Rester = TiddlyWeb::Resting->new(
    username => $opts{username},
    password => $opts{password},
    server   => $opts{server},
  );
  $Rester->workspace('wikiname');
  $Rester->get_page('my_page');
}

=head1 DESCRIPTION

C<TiddlyWeb::Resting> is a module designed to allow remote access
to the TiddlyWeb API for use in perl programs.

=head1 METHODS

=cut

Readonly my $BASE_URI => '';
Readonly my %ROUTES   => (
    page           => $BASE_URI . '/:type/:ws/tiddlers/:pname',
    pages          => $BASE_URI . '/:type/:ws/tiddlers',
    revisions      => $BASE_URI . '/:type/:ws/pages/:pname/revisions',
    recipe         => $BASE_URI . '/recipes/:ws',
    recipes        => $BASE_URI . '/recipes',
    bag            => $BASE_URI . '/bags/:ws',
    bags           => $BASE_URI . '/bags',
    search         => $BASE_URI . '/search',
);

field 'workspace';
field 'username';
field 'password';
field 'user_cookie';
field 'server';
field 'verbose';
field 'accept';
field 'filter';
field 'count';
field 'order';
field 'query';
field 'etag_cache' => {};
field 'http_header_debug';
field 'response';
field 'json_verbose';
field 'cookie';
field 'agent_string';

=head2 new

    my $Rester = TiddlyWeb::Resting->new(
        username => $opts{username},
        password => $opts{password},
        server   => $opts{server},
    );

    or

    my $Rester = TiddlyWeb::Resting->new(
        user_cookie => $opts{user_cookie},
        server      => $opts{server},
    );

Creates a TiddlyWeb::Resting object for the specified
server/user/password, or server/cookie combination.

=cut

sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {@_};
    open($self->{log}, ">wiklog");
    return bless $self, $class;
}

=head2 accept

    $Rester->accept($mime_type);

Sets the HTTP Accept header to ask the server for a specific
representation in future requests.

Standard representations:
http://www.socialtext.net/st-rest-docs/index.cgi?standard_representations

Common representations:

=over 4

=item text/plain

=item text/html

=item application/json

=back

=head2 get_page

    $Rester->workspace('wikiname');
    $Rester->get_page('page_name');

Retrieves the content of the specified page.  Note that
the workspace method needs to be called first to specify
which workspace to operate on.

=cut

sub get_page {
    my $self = shift;
    my $pname = shift;
    my $paccept;

    if (ref $pname){
	$paccept = $pname->{accept};
    }
    else {
	$paccept = $self->accept;
    }

    $pname = name_to_id($pname);
    my $accept = $paccept || 'text/plain';

    my $workspace = $self->workspace;
    my $uri = $self->_make_uri(
        'page',
        { pname => $pname, ws => $workspace }
    );
    $uri .= '?verbose=1' if $self->json_verbose;

    $accept = 'application/json' if $accept eq 'perl_hash';
    my ( $status, $content, $response ) = $self->_request(
        uri    => $uri,
        method => 'GET',
        accept => $accept,
    );

    if ( $status == 200 || $status == 404 ) {
        $self->{etag_cache}{$workspace}{$pname} = $response->header('etag');
        if (($self->accept || '') eq 'perl_hash') {
            if ($status == 200) {
                return decode_json($content);
            } else {
                # send an empty page
                return +{
                    text => 'Not found',
                    tags => [],
                    modifier => '',
                    modified => '',
                    bag => '',
                };
            }
        }
        return $content;
    }
    else {
        die "$status: $content\n";
    }
}


=head2 put_page

    $Rester->workspace('wikiname');
    $Rester->put_page('page_name',$content);

Save the content as a page in the wiki.  $content can either be a string,
which is treated as wikitext, or a hash with the following keys:

=over

=item content

A string which is the page's wiki content or a hash of content
plus other stuff.

=item date

RFC 2616 HTTP Date format string of the time the page was last edited

=item from

A username of the last editor of the page. If the the user does not exist it
will be created, but will not be added to the workspace.

=back

=cut
sub put_page {
    my $self         = shift;
    my $pname        = shift;
    my $page_content = shift;

    my $bag;
    my $type = 'text/plain';
    if ( ref $page_content ) {
        $type         = 'application/json';
        my $dict = {
            'text' => $page_content->{content},
            'tags' => $page_content->{tags},
            'fields' => $page_content->{fields},
        };
        $bag = $page_content->{bag};
        $page_content = encode_json($dict);
    }

    my $workspace = $self->workspace;
    my $uri;
    if ($bag) {
        $uri = $self->_make_uri(
            'page',
            { pname => $pname, ws => $bag, type => 'bags' }
        );
    } else {
        $uri = $self->_make_uri(
            'page',
            { pname => $pname, ws => $workspace }
        );
    }

    my %extra_opts;
    my $page_id = name_to_id($pname);
    if (my $prev_etag = $self->{etag_cache}{$workspace}{$page_id}) {
        $extra_opts{if_match} = $prev_etag;
    }
    print {$self->{log}} scalar(localtime(time)), 'if_match', $extra_opts{if_match}, "\n";

    my ( $status, $content ) = $self->_request(
        uri     => $uri,
        method  => 'PUT',
        type    => $type,
        content => $page_content,
        %extra_opts,
    );

    if ( $status == 204 || $status == 201 ) {
        return $content;
    }
    else {
        die "$status: $content\n";
    }
}

# REVIEW: This is here because of escaping problems we have with
# apache web servers. This code effectively translate a Page->uri
# to a Page->id. By so doing the troublesome characters are factored
# out, getting us past a bug. This change should _not_ be maintained
# any longer than strictly necessary, primarily because it
# creates an informational dependency between client and server
# code by representing name_to_id translation code on both sides
# of the system. Since it is not used for page PUT, new pages
# will safely have correct page titles.
#
# This method is useful for clients, so lets make it public.  In the
# future, this call could go to the server to reduce code duplication.

=head2 name_to_id

    my $id = $Rester->name_to_id($name);
    my $id = Socialtext::Resting::name_to_id($name);

Convert a page name into a page ID.  Can be called as a method or 
as a function.

=cut

sub _name_to_id { name_to_id(@_) }
sub name_to_id { return shift; }
# sub name_to_id {
#     my $id = shift;
#     $id = shift if ref($id); # handle being called as a method
#     $id = '' if not defined $id;
#     $id =~ s/[^\p{Letter}\p{Number}\p{ConnectorPunctuation}\pM]+/_/g;
#     $id =~ s/_+/_/g;
#     $id =~ s/^_(?=.)//;
#     $id =~ s/(?<=.)_$//;
#     $id =~ s/^0$/_/;
#     $id = lc($id);
#     return $id;
# }


sub _make_uri {
    my $self         = shift;
    my $thing        = shift;
    my $replacements = shift;

    unless ($replacements->{type}) {
        $replacements->{type} = 'recipes';
    }

    my $uri = $ROUTES{$thing};

    # REVIEW: tried to do this in on /g go but had issues where
    # syntax errors were happening...
    foreach my $stub ( keys(%$replacements) ) {
        my $replacement
            = URI::Escape::uri_escape_utf8( $replacements->{$stub} );
        $uri =~ s{/:$stub\b}{/$replacement};
    }

    return $uri;
}

=head2 get_pages

    $Rester->workspace('wikiname');
    $Rester->get_pages();

List all pages in the wiki.

=cut

sub get_pages {
    my $self = shift;

    return $self->_get_things('pages');
}


=head2 get_revisions

    $Rester->get_revisions($page)

List all the revisions of a page.

=cut

sub get_revisions {
    my $self = shift;
    my $pname = shift;

    return $self->_get_things( 'revisions', pname => $pname );
}

sub get_search {
    my $self = shift;

    return $self->_get_things( 'search' );
}


sub _extend_uri {
    my $self = shift;
    my $uri = shift;
    my @extend;

    if ( $self->filter ) {
        push (@extend, "select=" . $self->filter);
    }
    if ( $self->query ) {
        push (@extend, "q=" . $self->query);
    }
    if ( $self->order ) {
        push (@extend, "sort=" . $self->order);
    }
    if ( $self->count ) {
        push (@extend, "limit=" . $self->count);
    }
    if (@extend) {
        $uri .= "?" . join(';', @extend);
    }
    return $uri;

}
sub _get_things {
    my $self         = shift;
    my $things       = shift;
    my %replacements = @_;
    my $accept = $self->accept || 'text/plain';

    my $uri = $self->_make_uri(
        $things,
        { ws => $self->workspace, %replacements }
    );
    $uri = $self->_extend_uri($uri);

    # Add query parameters from a
    if ( exists $replacements{_query} ) {
        my @params;
        for my $q ( keys %{ $replacements{_query} } ) {
            push @params, "$q=" . $replacements{_query}->{$q};
        }
        if (my $query = join( ';', @params )) {
            if ( $uri =~ /\?/ ) {
                $uri .= ";$query";
            }
            else {
                $uri .= "?$query";
            }
        }
    }

    $accept = 'application/json' if $accept eq 'perl_hash';
    my ( $status, $content ) = $self->_request(
        uri    => $uri,
        method => 'GET',
        accept => $accept,
    );

    if ( $status == 200 and wantarray ) {
        return ( grep defined, ( split "\n", $content ) );
    }
    elsif ( $status == 200 ) {
        return decode_json($content) 
            if (($self->accept || '') eq 'perl_hash');
        return $content;
    }
    elsif ( $status == 404 ) {
        return ();
    }
    elsif ( $status == 302 ) {
        return $self->response->header('Location');
    }
    else {
        die "$status: $content\n";
    }
}

=head2 get_workspace

    $Rester->get_workspace();

Return the metadata about a particular workspace.

=cut

sub get_workspace {
    my $self = shift;
    my $wksp = shift;

    my $prev_wksp = $self->workspace();
    $self->workspace($wksp) if $wksp;
    my $result = $self->_get_things('workspace');
    $self->workspace($prev_wksp) if $wksp;
    return $result;
}

=head2 get_workspaces

    $Rester->get_workspaces();

List all workspaces on the server

=cut

sub get_workspaces {
    my $self = shift;

    return $self->_get_things('workspaces');
}


sub _request {
    my $self = shift;
    my %p    = @_;
    use Data::Dumper;
    print {$self->{log}} scalar(localtime(time)), Dumper(\%p), "\n";
    my $ua   = LWP::UserAgent->new(agent => $self->agent_string);
    my $server = $self->server;
    die "No server defined!\n" unless $server;
    $server =~ s/\/$//;
    my $uri  = "$server$p{uri}";
    warn "uri: $uri\n" if $self->verbose;

    my $request = HTTP::Request->new( $p{method}, $uri );
    if ( $self->user_cookie ) {
        $request->header( 'Cookie' => 'tiddlyweb_user=' . $self->user_cookie );
    } else {
        $request->authorization_basic( $self->username, $self->password );
    }
    $request->header( 'Accept'       => $p{accept} )   if $p{accept};
    $request->header( 'Content-Type' => $p{type} )     if $p{type};
    $request->header( 'If-Match'     => $p{if_match} ) if $p{if_match};
    print {$self->{log}} scalar(localtime(time)), Dumper($request->headers), "\n";
    if ($p{method} eq 'PUT') {
        my $content_len = 0;
        $content_len = do { use bytes; length $p{content} } if $p{content};
        $request->header( 'Content-Length' => $content_len );
    }

    if (my $cookie = $self->cookie) {
        $request->header('cookie' => $cookie);
    }
    $request->content( $p{content} ) if $p{content};
    $self->response( $ua->simple_request($request) );

    if ( $self->http_header_debug ) {
        use Data::Dumper;
        warn "Code: "
            . $self->response->code . "\n"
            . Dumper $self->response->headers;
    }

    # We should refactor to not return these response things
    return ( $self->response->code, $self->response->content,
        $self->response );
}

=head2 response

    my $resp = $Rester->response;

Return the HTTP::Response object from the last request.

=head1 AUTHORS / MAINTAINERS

Luke Closs C<< <luke.closs@socialtext.com> >>

Shawn Devlin C<< <shawn.devlin@socialtext.com> >>

Jeremy Stashewsky C<< <jeremy.stashewsky@socialtext.com> >>

=head2 CONTRIBUTORS

Chris Dent

Kirsten Jones

Michele Berg - get_revisions()

=cut

1;
