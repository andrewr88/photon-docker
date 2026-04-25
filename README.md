Have your own geocoder up and running within the hour, you will require about 60GB of disk space and has no further dependencies. If you select a specific country, you can reduce the necessary disk space.

Feel free to fork and improve. 

See this [blog post](https://tonsnoei.nl/en/post/2023/03/20/set-up-your-own-geocoder-api/) for more info.


# Run

The image itself is pretty small, the first time the container is executed, a 60GB searchindex will be downloaded. The [blog post](https://tonsnoei.nl/en/post/2023/03/20/set-up-your-own-geocoder-api/) explains how to use only a specific country or region.

The data volume is exposed as `/photon/photon_data` and can be mounted, this way you'll only have to download the data once.

## With `docker run`

```bash
docker run -p 2322:2322 -it tonsnoei/photon-geocoder:latest
```

## Search

```
http://localhost:2322/api?q=amsterdam
```
*For more details on the API check the Photon [github repository](https://github.com/komoot/photon).*



## Build from git
https://github.com/tonsnoei/photon-docker

### With docker-compose
```bash
docker-compose build #optional
docker-compose up
```
*Note: if you abort the download, you have to remove the volume `photon_data` before restarting the container*


## Updates

The container periodically polls for new versions of the search index. When one is found, the new index is downloaded into `/photon/photon_data/staged/` while Photon keeps serving the old index. On the next container restart, the staged index is moved into place before Photon starts.

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `UPDATE_CHECK_INTERVAL_SECONDS` | `86400` | How often to poll for a new index. |
| `NTFY_URL` | _unset_ | Base URL of an [ntfy](https://ntfy.sh) server (e.g. `https://ntfy.sh`). |
| `NTFY_TOPIC` | _unset_ | ntfy topic to post to. |
| `NTFY_TOKEN` | _unset_ | Bearer token used for ntfy auth. |

When all three `NTFY_*` variables are set, a notification is sent every time a new index has been staged so you know it's time to restart the container.

## FAQ

 - How do I pass arguments to the `photon.jar` ?

   *The entrypoint accepts arguments for the `photon.jar`, you can invoke it by using `docker exec`*
 - Do I need to have nominatim ?

   *The container downloads the latest prebuilt search index, there is no immediate need to have nominatim installed.*

 - What is Photon ?
  
   *Photon is a geocoder, check out [their website](https://photon.komoot.de/) and their [github repository](https://github.com/komoot/photon)*
