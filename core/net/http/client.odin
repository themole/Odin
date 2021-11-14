package http

import "core:net"
import "core:fmt"
import "core:mem"
import "core:sync"

Request_Status :: enum {
	Unknown, // NOTE: ID does not exist
	Need_Send,
	Send_Failed,
	Wait_Reply,
	Recv_Failed,
	Done,
}

Client_Request :: struct {
	request:   Request,
	response:  Response,
	socket:    net.Tcp_Socket, // only valid if status == .Wait_Reply
	status:    Request_Status,
}


Client :: struct {
	next_id:  Request_Id,
	requests: map[Request_Id]Client_Request,
	lock:     sync.Ticket_Mutex,
}

client_init :: proc(using c: ^Client, allocator := context.allocator) {
	sync.ticket_mutex_init(&lock);
	next_id = 0;
}

client_destroy :: proc(using c: ^Client) {
	for _, cr in c.requests {
		request_destroy(cr.request);
	}
	delete(requests);
	c^ = {};
}


Request_Id :: distinct int;

client_submit_request :: proc(using c: ^Client, req: Request) -> Request_Id {
	cr := Client_Request{
		request = req,
		response = {},
		status = .Need_Send,
	};

	{
		sync.ticket_mutex_lock(&lock);
		defer sync.ticket_mutex_unlock(&lock);
		id := next_id;
		next_id += 1;
		requests[id] = cr;
		return Request_Id(id);
	}
}

client_check_for_response :: proc(using c: ^Client, id: Request_Id) -> (response: Response, status: Request_Status) {
	cr: Client_Request;
	ok: bool;
	{
		sync.ticket_mutex_lock(&lock);
		defer sync.ticket_mutex_unlock(&lock);
		cr, ok = requests[id];
	}

	if !ok {
		status = .Unknown;
		return;
	}
	return cr.response, cr.status;
}

client_wait_for_response :: proc(using c: ^Client, id: Request_Id) -> (response: Response, status: Request_Status) {
	loop: for {
		done: bool;
		response, status = client_check_for_response(c, id);
		switch status {
		case .Unknown:
			return; // NOTE: ID did not exist!
		case .Done, .Send_Failed, .Recv_Failed:
			break loop;
		case .Need_Send, .Wait_Reply:
			// NOTE: gotta wait - might as well use the current thread to advance the requests
			// TODO: block until there's stuff to process rather than spinning
			client_process_requests(c);
		}
	}

	sync.ticket_mutex_lock(&lock);
	defer sync.ticket_mutex_unlock(&lock);
	delete_key(&requests, id);
	return;
}

client_execute_request :: proc(using c: ^Client, req: Request) -> (response: Response, status: Request_Status) {
	id := client_submit_request(c, req);
	// return client_wait_for_response(c, id);
	response, status = client_wait_for_response(c, id);
	return;
}

client_process_requests :: proc(using c: ^Client) {
	close_socket :: proc(s: ^net.Tcp_Socket) {
		net.close(s^);
		s^ = {};
	}

	for id, req in &requests {
		sync.ticket_mutex_lock(&lock);
		defer sync.ticket_mutex_unlock(&lock);

		switch req.status {
		case .Need_Send:
			skt, ok := send_request(req.request);
			if ok {
				req.socket = skt;
				req.status = .Wait_Reply;
			} else {
				req.status = .Send_Failed;
				close_socket(&req.socket);
			}
		case .Wait_Reply:
			resp, ok := recv_response(req.socket);
			if ok {
				req.response = resp;
				req.status = .Done;
			} else {
				req.status = .Recv_Failed;
			}
			close_socket(&req.socket);
		case .Done, .Send_Failed, .Recv_Failed:
			// do nothing.
			// it'll be removed from the list when user code
			// asks for it.
		case .Unknown:
			unreachable();
		}
	}
}

/*
Client_Request_State :: enum u8 {
	Pending,
	Connecting,
	Failed,
	// TODO
}

Client_Request_Token :: distinct u32;

Client_Connecting_Request 	:: struct { req: Request, skt: net.Socket };
Client_Failed_Request 		:: struct { req: Request, error: net.Dial_Error };
Client_Reading_Response     :: struct { req: Request, skt: net.Socket, resp: Response };

Client_Request :: union {
	Client_Connecting_Request,
	Client_Failed_Request,
	Client_Reading_Response,
}

client_begin_request :: proc(using c: ^Client, req: Request) -> (token: Client_Request_Token, ok: bool) {
	slot := new(Client_Request, allocator);
	if slot == nil do return;
	defer if !ok do delete(slot);

	addr4, addr6, addr_ok := net.resolve(req.host);
	if !addr_ok do return;
	addr := addr4 != nil ? addr4 : addr6;

	sync.ticket_mutex_lock(&lock);
	defer sync.ticket_mutex_unlock(&lock);

	append(&requests, slot);
	tk := Client_Request_Token(len(requests));  // tokens are 1-based because 0 is the nil value.
	assert(tk > 0);

	skt, err := net.start_dial(addr, 80);
	if err != nil do return;

	slot^ = Client_Connecting_Request {
		req = req,
		skt = skt,
	};

	token = tk;
	ok = true;
	return;
}

client_poll_events :: proc(using c: ^Client) -> (updated: int) {
	sync.ticket_mutex_lock(&lock);
	defer sync.ticket_mutex_unlock(&lock);

	for req, i in requests {
		switch r in req {
		case Client_Connecting_Request:
			done, err := net.try_finish_dial(c);
			if err != nil {
				net.close(c);
				requests[i] = Client_Failed_Request {
					req = r.req,
					error = err,
				};
				updated += 1;
				fmt.println("failed");
				continue;
			}

			if done {
				write_request_to_socket(&r.req);
				requests[i] = Client_Reading_Response {
					req = r.req,
					skt = r.skt,
				};
				requests[i].resp.headers.allocator = request_allocator;
				fmt.println("connected");
				updated += 1;
			}

		case Client_Reading_Response:
			buf: [4096]byte = ---;
			n, err := net.try_read(r.skt, buf[:]);
			if n == 0 do continue;



			updated += 1;
		}
	}
}

client_get_response :: proc(using c: ^Client, token: Client_Request_Token) -> (done: bool, resp: Response) {
	i := int(token);
	if i < 0 || i >= len(requests) do return;

	switch r in requests[i] {
	case Client_Completed_Request:
		done = true;
		resp = r.resp;
	}
	return;
}


// TODO(tetra): maybe take request by ptr, and modify when response is ready?
client_execute_request :: proc(c: ^Client, req: Request) -> (resp: Response, ok: bool) {
	tok, ok := client_begin_request(c, req);
	for {
		if client_poll_events(c) == 0 {
			sync.yield_processor();
			continue;
		}

		done: bool;
		done, resp, err = client_get_response(c, tok);
		if done do break;

		sync.yield_processor();
	}

	ok = true;
	return;
}
*/