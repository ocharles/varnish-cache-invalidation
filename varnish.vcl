backend be_musicbrainz {
 .host = "127.0.0.1";
 .port = "5000";
}

sub vcl_recv {
	if (req.request == "BAN") {
        set req.url = regsub(req.url, "^\/", "");
	    ban("obj.http.dependencies ~ " + req.url);
	    error 200 "Cached Cleared Successfully. " + "obj.http.dependencies ~ " + req.url;
	}
	return(lookup);
}

sub vcl_fetch {
    set beresp.ttl = 1w;
    set beresp.http.Last-Modified = now;
}
