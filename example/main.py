# These two modules allow us to run a web server.
from flask import Flask, render_template
from flask_socketio import SocketIO
# This module lets us pick random numbers, you can remove it later.
import random

# Here, we create the neccesary base app. You don't need to worry about this.
app = Flask(__name__)
socketio = SocketIO(app)

# When someone requests the root page from our web server, we return 'index.html'.
@app.route('/')
def index():
    return render_template('index.html')

# This function runs in the background to transmit data to connected clients.
def background_thread():
    while True:
        # We sleep here for a single second, but this can be increased or decreased depending on how quickly you want data to be pushed to clients.
        socketio.sleep(1)
        # Then, we emit an event called "update_data" - but this can actually be whatever we want - with the data being a dictionary
        # where 'randomNumber' is set to a random number we choose here. You should replace the data being sent back with your sensor data
        # that you fetch from things connected to your Pi.
        socketio.emit(
            'update_data',
            {
                'randomNumber': random.randint(1, 100),
                # you can add more here! for instance, something along the lines of:
                # 'mySensor': mysensor.get_sensor_data(),
            }
        )
        # To add a your first new sensor, try giving https://docs.aerospacejam.org/getting-started/first-sensor a read!

# This function runs when someone connects to the server - and all we do is start the background thread to update the data.
@socketio.on('connect')
def handle_connect():
    print('Client connected')
    socketio.start_background_task(target=background_thread)

# This function is called
def main():
    # These specific arguments are required to make sure the webserver is hosted in a consistent spot, so don't change them unless you know what you're doing.
    socketio.run(app, host='0.0.0.0', port=80, allow_unsafe_werkzeug=True)

if __name__ == '__main__':
    main()
