"""Deterministic App Server fixture; never calls a model."""
import json
import os
import sys
import time
import threading

write_lock = threading.Lock()

mode = os.environ.get('COMPL_FAKE_MODE', 'success')
log = os.environ.get('COMPL_FAKE_LOG')
count = 0
initialized = False


def send(message):
    wire = json.dumps(message) + '\n'
    # Exercise messages fragmented across stdout callbacks.
    with write_lock:
        sys.stdout.write(wire[:7])
        sys.stdout.flush()
        time.sleep(0.002)
        sys.stdout.write(wire[7:])
        sys.stdout.flush()


def reply(request, result):
    send({'id': request['id'], 'result': result})


for line in sys.stdin:
    request = json.loads(line)
    if log:
        with open(log, 'a') as output:
            output.write(line)
    method = request.get('method')
    if method == 'initialize':
        if mode == 'hang_init':
            continue
        reply(request, {})
    elif method == 'initialized':
        initialized = True
    elif method == 'account/read':
        assert initialized
        reply(request, {'account': None if mode == 'signed_out' else {'type': 'chatgpt'}})
    elif method == 'thread/start':
        assert request['params']['ephemeral'] is True
        assert request['params']['sandbox'] == 'read-only'
        count += 1
        if mode == 'slow_thread':
            time.sleep(0.1)
        reply(request, {'thread': {'id': 'thread-' + str(count)}})
    elif method == 'turn/start':
        params = request['params']
        assert params['outputSchema']['required'] in (['text'], ['text', 'position'])
        assert params['approvalPolicy'] == 'never'
        thread = params['threadId']
        turn = 'turn-' + str(count)
        if mode == 'slow_turn':
            time.sleep(0.1)
        if mode == 'exit':
            sys.exit(2)
        if mode == 'rpc_error':
            send({'id': request['id'], 'error': {'code': -1, 'message': 'Usage limit reached'}})
            continue
        reply(request, {'turn': {'id': turn}})
        if mode in ('hang', 'slow_turn', 'slow_thread'):
            continue
        if mode == 'bad_wire':
            print('invalid JSON', flush=True)
            continue
        if mode == 'approval':
            send({'id': 'approval-1', 'method': 'item/commandExecution/requestApproval',
                  'params': {'threadId': thread, 'turnId': turn}})
            continue
        text = json.dumps({'text': 'one\ntwo', 'position': {'row': 0, 'col': 1}})
        if mode.startswith('stream'):
            if mode == 'stream_long':
                text = json.dumps({'text': '1\n2\n3\n4\n5\n6\n7\n8\n9'})
            else:
                text = json.dumps({'text': 'one\ntwo "é😀"\\end'})
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn,
                  'item': {'id': 'commentary', 'type': 'agentMessage', 'phase': 'commentary'}}})
            send({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn,
                  'itemId': 'commentary', 'delta': '{"text":"Do not preview this"}'}})
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn,
                  'item': {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer'}}})
            for char in text:
                send({'method': 'item/agentMessage/delta', 'params': {'threadId': thread,
                      'turnId': turn, 'itemId': 'answer', 'delta': char}})
            def finish_stream(thread=thread, turn=turn, text=text):
                time.sleep(0.15)
                send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn,
                      'item': {'id': 'answer', 'type': 'agentMessage', 'text': text, 'phase': 'final_answer'}}})
                send({'method': 'turn/completed', 'params': {'threadId': thread,
                      'turn': {'id': turn, 'status': 'failed' if mode == 'stream_error' else 'completed',
                               'error': {'message': 'Generation failed'} if mode == 'stream_error' else None}}})
            threading.Thread(target=finish_stream, daemon=True).start()
            continue
        if mode == 'bad_output':
            text = 'not JSON'
        send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn,
              'item': {'type': 'agentMessage', 'text': text, 'phase': 'final_answer'}}})
        send({'method': 'turn/completed', 'params': {'threadId': thread,
              'turn': {'id': turn, 'status': 'completed', 'error': None}}})
    elif method in ('thread/unsubscribe', 'turn/interrupt'):
        reply(request, {})
