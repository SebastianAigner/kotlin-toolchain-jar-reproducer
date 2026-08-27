FROM scratch

# Keep this image deliberately trivial: the only filesystem layer is the
# executable JAR, so a changed layer digest can only come from that JAR.
COPY build/reproducer/app.jar /app.jar
